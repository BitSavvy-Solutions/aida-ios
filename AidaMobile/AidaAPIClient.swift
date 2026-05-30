import Foundation

struct AidaMessagePayload: Encodable {
    let type: String
    let content: String
    let image_data_urls: [String]?
}

struct AidaChatPayload: Encodable {
    let message_history: [AidaMessagePayload]
    let email: String
    let page_path: String
    let language: String
    let model: String
    let user_id: String?
    let image_data_urls: [String]?
    let web_search_enabled: Bool?
    let webSearchEnabled: Bool?
}

struct AidaStreamEvent: Decodable {
    let delta_content: String?
    let reasoning_content: String?
    let content: String?
    let response: String?
    let message: String?
    let text: String?
    let error: String?
    let detail: String?

    var assistantTextDelta: String? {
        [delta_content, content, response, message, text]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let decodedValue = value.decodingUnicodeEscapes()
                return decodedValue.isEmpty ? nil : decodedValue
            }
            .first
    }
}

enum AidaAPIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case emptyResponse(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid response."
        case let .httpError(statusCode, message):
            return "Request failed (\(statusCode)): \(message)"
        case let .emptyResponse(message):
            return message
        }
    }
}

final class AidaAPIClient {
    static let productionChatURL = URL(string: "https://aida-agentbackend-prod.graydune-dda4d1ba.canadaeast.azurecontainerapps.io/api/iverse_agent")!
    static let developmentChatURL = URL(string: "https://aida-agentbackend-dev.graydune-dda4d1ba.canadaeast.azurecontainerapps.io/api/iverse_agent")!

    private static var chatURL: URL {
#if DEBUG
        developmentChatURL
#else
        productionChatURL
#endif
    }

    func streamChat(
        payload: AidaChatPayload,
        apiToken: String?,
        onEvent: @escaping @MainActor (AidaStreamEvent) -> Void
    ) async throws {
        print("[AidaAPIClient] POST \(Self.chatURL.absoluteString)")

        var request = URLRequest(url: Self.chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")

        if let apiToken, !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AidaAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = try await collectResponseBody(from: bytes)
            throw AidaAPIError.httpError(statusCode: httpResponse.statusCode, message: body)
        }

        var rawResponse = ""
        var emittedAnyContent = false
        var textDecoder = StreamEventTextDecoder()

        for try await line in bytes.lines {
            if Task.isCancelled {
                break
            }

            rawResponse += line + "\n"

            if line.isEmpty {
                continue
            }

            if line.hasPrefix("data: ") {
                let didEmit = try await decodeEvent(from: [line], textDecoder: &textDecoder, onEvent: onEvent)
                emittedAnyContent = emittedAnyContent || didEmit
            }
        }

        if !emittedAnyContent {
            let fallbackDidEmit = try await decodeFallbackResponse(rawResponse, textDecoder: &textDecoder, onEvent: onEvent)
            if !fallbackDidEmit {
                let snippet = debugSnippet(from: rawResponse)
                if !snippet.isEmpty {
                    print("[AidaAPIClient] Unsupported raw response:\n\(snippet)")
                }
                throw AidaAPIError.emptyResponse(
                    message: snippet.isEmpty
                        ? "The server returned an empty or unsupported response."
                        : "Unsupported server response: \(snippet)"
                )
            }
        }
    }

    private func decodeEvent(
        from lines: [String],
        textDecoder: inout StreamEventTextDecoder,
        onEvent: @escaping @MainActor (AidaStreamEvent) -> Void
    ) async throws -> Bool {
        let dataLines = lines.compactMap { line -> String? in
            guard line.hasPrefix("data: ") else { return nil }
            return String(line.dropFirst(6))
        }

        guard !dataLines.isEmpty else { return false }

        let rawPayload = dataLines.joined(separator: "\n")
        if rawPayload == "[DONE]" {
            return false
        }

        guard let jsonData = rawPayload.data(using: .utf8) else { return false }

        do {
            let event = try JSONDecoder().decode(AidaStreamEvent.self, from: jsonData)
            if let errorMessage = [event.error, event.detail]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                throw AidaAPIError.emptyResponse(message: errorMessage)
            }
            await onEvent(event)
            return event.assistantTextDelta != nil
        } catch let error as AidaAPIError {
            throw error
        } catch {
            if let event = textDecoder.recoverEvent(from: rawPayload) {
                if let errorMessage = [event.error, event.detail]
                    .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .first(where: { !$0.isEmpty }) {
                    throw AidaAPIError.emptyResponse(message: errorMessage)
                }

                await onEvent(event)
                return event.assistantTextDelta != nil
            }

            print("[AidaAPIClient] Failed to decode SSE event: \(rawPayload)")
            return false
        }
    }

    private func collectResponseBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var chunks: [String] = []

        for try await line in bytes.lines {
            chunks.append(line)
        }

        let body = chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "Unknown server error." : body
    }

    private func decodeFallbackResponse(
        _ rawResponse: String,
        textDecoder: inout StreamEventTextDecoder,
        onEvent: @escaping @MainActor (AidaStreamEvent) -> Void
    ) async throws -> Bool {
        let trimmed = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("data: ") {
            let lines = trimmed
                .split(separator: "\n")
                .map(String.init)
                .filter { $0.hasPrefix("data: ") }
            return try await decodeEvent(from: lines, textDecoder: &textDecoder, onEvent: onEvent)
        }

        if let data = trimmed.data(using: .utf8),
           let event = try? JSONDecoder().decode(AidaStreamEvent.self, from: data) {
            if let errorMessage = [event.error, event.detail]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                throw AidaAPIError.emptyResponse(message: errorMessage)
            }

            await onEvent(event)
            return event.assistantTextDelta != nil
        }

        print("[AidaAPIClient] Treating raw response as plain text fallback:\n\(debugSnippet(from: trimmed))")
        await onEvent(
            AidaStreamEvent(
                delta_content: trimmed.decodingUnicodeEscapes(),
                reasoning_content: nil,
                content: nil,
                response: nil,
                message: nil,
                text: nil,
                error: nil,
                detail: nil
            )
        )
        return true
    }

    private func debugSnippet(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.count <= 500 {
            return trimmed
        }

        let prefix = trimmed.prefix(500)
        return "\(prefix)..."
    }
}

private struct StreamEventTextDecoder {
    private var pendingHighSurrogateEscape: String?

    mutating func recoverEvent(from rawPayload: String) -> AidaStreamEvent? {
        let delta = decodedValue(forKey: "delta_content", in: rawPayload)
        let content = decodedValue(forKey: "content", in: rawPayload)
        let response = decodedValue(forKey: "response", in: rawPayload)
        let message = decodedValue(forKey: "message", in: rawPayload)
        let text = decodedValue(forKey: "text", in: rawPayload)
        let error = decodedValue(forKey: "error", in: rawPayload)
        let detail = decodedValue(forKey: "detail", in: rawPayload)

        guard delta != nil || content != nil || response != nil || message != nil || text != nil || error != nil || detail != nil else {
            return nil
        }

        return AidaStreamEvent(
            delta_content: delta,
            reasoning_content: nil,
            content: content,
            response: response,
            message: message,
            text: text,
            error: error,
            detail: detail
        )
    }

    private mutating func decodedValue(forKey key: String, in rawPayload: String) -> String? {
        guard let escapedValue = firstCapturedValue(forKey: key, in: rawPayload) else {
            return nil
        }

        var working = escapedValue
        if let pendingHighSurrogateEscape {
            working = pendingHighSurrogateEscape + working
            self.pendingHighSurrogateEscape = nil
        }

        if let trailingHighSurrogateEscape = trailingHighSurrogateEscape(in: working) {
            working.removeLast(trailingHighSurrogateEscape.count)
            pendingHighSurrogateEscape = trailingHighSurrogateEscape
        }

        guard !working.isEmpty else { return nil }
        return decodeJSONStringFragment(working) ?? working.decodingUnicodeEscapes()
    }

    private func firstCapturedValue(forKey key: String, in rawPayload: String) -> String? {
        let pattern = #""\#(key)"\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(rawPayload.startIndex..<rawPayload.endIndex, in: rawPayload)
        guard let match = regex.firstMatch(in: rawPayload, range: range),
              let captureRange = Range(match.range(at: 1), in: rawPayload) else {
            return nil
        }

        return String(rawPayload[captureRange])
    }

    private func trailingHighSurrogateEscape(in value: String) -> String? {
        let pattern = #"(?i)(\\uD[89AB][0-9A-F]{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let captureRange = Range(match.range(at: 1), in: value) else {
            return nil
        }

        return String(value[captureRange])
    }

    private func decodeJSONStringFragment(_ fragment: String) -> String? {
        guard let data = "\"\(fragment)\"".data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }
}

private extension String {
    func decodingUnicodeEscapes() -> String {
        guard contains("\\u") || contains("\\U") else { return self }

        guard let data = "\"\(self)\"".data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return self
        }

        return decoded
    }
}
