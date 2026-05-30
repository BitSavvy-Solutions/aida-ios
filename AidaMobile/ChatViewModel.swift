import Combine
import Foundation
import UIKit

struct ModelOption: Identifiable, Hashable {
    let value: String
    let label: String

    var id: String { value }

    static let defaults: [ModelOption] = [
        .init(value: "deepseek/deepseek-v4-pro", label: "Deepseek 4 Pro"),
        .init(value: "deepseek/deepseek-v3.2", label: "Deepseek 3.2"),
        .init(value: "openai/gpt-5.1", label: "GPT-5.1"),
        .init(value: "google/gemini-3.1-pro-preview", label: "Gemini Pro 3"),
        .init(value: "~anthropic/claude-sonnet-latest", label: "Claude Sonnet"),
        .init(value: "perplexity/sonar", label: "Perplexity Sonar")
    ]
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    var imageAttachments: [ChatImageAttachment]

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        imageAttachments: [ChatImageAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.imageAttachments = imageAttachments
    }
}

struct ChatImageAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var mimeType: String
    var dataURL: String

    init(id: UUID = UUID(), name: String, mimeType: String, dataURL: String) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.dataURL = dataURL
    }
}

struct DraftImageImport: Sendable {
    let data: Data
    let name: String
}

struct SavedChat: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
    var projectID: UUID?
}

struct SavedProject: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var iconSystemName: String
    var iconColorName: String
    var createdAt: Date
    var updatedAt: Date
}

extension ChatMessage: Codable {}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var selectedModel: String
    @Published var userEmail: String
    @Published var userId: String
    @Published var apiToken: String
    @Published var isSending = false
    @Published var isWebSearchEnabled = false
    @Published var errorMessage: String?
    @Published var showingSettings = false
    @Published private(set) var draftImageAttachments: [ChatImageAttachment] = []
    @Published private(set) var editingMessageID: UUID?
    @Published private(set) var savedChats: [SavedChat]
    @Published private(set) var savedProjects: [SavedProject]
    @Published private(set) var currentChatID: UUID?
    @Published private(set) var currentProjectID: UUID?

    private let client = AidaAPIClient()
    private var currentStreamTask: Task<Void, Never>?
    private var activeStreamSessionID = UUID()
    private var activeStreamingAssistantMessageID: UUID?
    private let defaults: UserDefaults

    private enum Keys {
        static let selectedModel = "native-selected-model"
        static let userEmail = "native-user-email"
        static let userId = "native-user-id"
        static let apiToken = "native-api-token"
        static let savedChats = "native-saved-chats"
        static let savedProjects = "native-saved-projects"
        static let currentChatID = "native-current-chat-id"
        static let currentProjectID = "native-current-project-id"
        static let personalityPreset = "aida-personality-preset"
        static let customPersonalityInstructions = "aida-custom-personality-instructions"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedModel = defaults.string(forKey: Keys.selectedModel) ?? ModelOption.defaults[0].value
        self.userEmail = defaults.string(forKey: Keys.userEmail) ?? ""
        self.userId = defaults.string(forKey: Keys.userId) ?? ""
        self.apiToken = defaults.string(forKey: Keys.apiToken) ?? ""
        self.savedChats = Self.loadSavedChats(from: defaults)
        self.savedProjects = Self.loadSavedProjects(from: defaults)
        self.currentChatID = defaults.string(forKey: Keys.currentChatID).flatMap(UUID.init(uuidString:))

        let storedProjectID = defaults.string(forKey: Keys.currentProjectID).flatMap(UUID.init(uuidString:))
        if let storedProjectID,
           savedProjects.contains(where: { $0.id == storedProjectID }) {
            self.currentProjectID = storedProjectID
        } else {
            self.currentProjectID = nil
        }

        if let currentChatID,
           let existingChat = savedChats.first(where: { $0.id == currentChatID }) {
            self.messages = existingChat.messages
            self.currentProjectID = existingChat.projectID
        } else {
            self.currentChatID = nil
        }
    }

    var selectedModelLabel: String {
        ModelOption.defaults.first(where: { $0.value == selectedModel })?.label ?? selectedModel
    }

    var hasStartedChat: Bool {
        currentChatID != nil && !messages.isEmpty
    }

    var currentChatTitle: String {
        guard let currentChatID,
              let title = savedChats.first(where: { $0.id == currentChatID })?.title else {
            return ""
        }

        return title
    }

    var currentProjectTitle: String {
        guard let currentProjectID,
              let project = savedProjects.first(where: { $0.id == currentProjectID }) else {
            return ""
        }

        return project.title
    }

    var hasRequiredIdentity: Bool {
        !trimmed(userEmail).isEmpty && (!trimmed(apiToken).isEmpty || !trimmed(userId).isEmpty)
    }

    func persistSettings() {
        defaults.set(selectedModel, forKey: Keys.selectedModel)
        defaults.set(userEmail, forKey: Keys.userEmail)
        defaults.set(userId, forKey: Keys.userId)
        defaults.set(apiToken, forKey: Keys.apiToken)
    }

    func sendMessage() {
        let text = trimmed(draft)
        let imageAttachments = draftImageAttachments
        guard !text.isEmpty || !imageAttachments.isEmpty else { return }
        guard hasRequiredIdentity else {
            errorMessage = "Enter your email and either a user ID or API token in Settings."
            showingSettings = true
            return
        }

        if let editingMessageID,
           let editIndex = messages.firstIndex(where: { $0.id == editingMessageID }) {
            messages.removeSubrange(editIndex...)
            self.editingMessageID = nil
            syncCurrentChat()
        }

        errorMessage = nil
        draft = ""
        draftImageAttachments.removeAll()

        ensureCurrentChatIfNeeded(withFirstUserMessage: text)

        let userMessage = ChatMessage(role: .user, text: text, imageAttachments: imageAttachments)
        messages.append(userMessage)
        syncCurrentChat()

        startAssistantResponse()
    }

    @discardableResult
    func regenerateAssistantMessage(messageID: UUID) -> Bool {
        guard hasRequiredIdentity else {
            errorMessage = "Enter your email and either a user ID or API token in Settings."
            showingSettings = true
            return false
        }

        guard let assistantIndex = messages.firstIndex(where: { $0.id == messageID && $0.role == .assistant }) else {
            return false
        }

        guard messages[..<assistantIndex].contains(where: { $0.role == .user }) else {
            return false
        }

        stopStreaming()
        messages.removeSubrange(assistantIndex...)
        errorMessage = nil
        editingMessageID = nil
        syncCurrentChat()

        startAssistantResponse()
        return true
    }

    @discardableResult
    func regenerateFromUserMessage(messageID: UUID) -> Bool {
        guard hasRequiredIdentity else {
            errorMessage = "Enter your email and either a user ID or API token in Settings."
            showingSettings = true
            return false
        }

        guard let userIndex = messages.firstIndex(where: { $0.id == messageID && $0.role == .user }) else {
            return false
        }

        stopStreaming()

        let removalStartIndex = messages.index(after: userIndex)
        if removalStartIndex < messages.endIndex {
            messages.removeSubrange(removalStartIndex...)
        }

        errorMessage = nil
        editingMessageID = nil
        syncCurrentChat()

        startAssistantResponse()
        return true
    }

    func stopStreaming() {
        activeStreamSessionID = UUID()
        if let assistantMessageID = activeStreamingAssistantMessageID {
            removeAssistantPlaceholderIfEmpty(id: assistantMessageID)
        }
        activeStreamingAssistantMessageID = nil
        currentStreamTask?.cancel()
        currentStreamTask = nil
        isSending = false
    }

    func clearConversation() {
        stopStreaming()
        syncCurrentChat()
        currentChatID = nil
        currentProjectID = nil
        messages.removeAll()
        draftImageAttachments.removeAll()
        errorMessage = nil
        editingMessageID = nil
        draft = ""
        persistCurrentProjectID()
        persistCurrentChatID()
    }

    @discardableResult
    func beginEditing(messageID: UUID) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .user else {
            return false
        }

        stopStreaming()
        draft = messages[index].text
        draftImageAttachments = messages[index].imageAttachments
        editingMessageID = messageID
        errorMessage = nil
        return true
    }

    func cancelEditing() {
        editingMessageID = nil
    }

    func removeDraftImageAttachment(id: UUID) {
        draftImageAttachments.removeAll(where: { $0.id == id })
    }

    func clearDraftImageAttachments() {
        draftImageAttachments.removeAll()
    }

    func addDraftImageImports(_ imports: [DraftImageImport]) {
        let preparedAttachments = imports.compactMap(ChatImageAttachment.prepare(from:))
        guard !preparedAttachments.isEmpty else { return }
        draftImageAttachments.append(contentsOf: preparedAttachments)
    }

    func createProject(title: String, iconSystemName: String, iconColorName: String) {
        let normalizedTitle = trimmed(title)
        guard !normalizedTitle.isEmpty else { return }

        let now = Date()
        let project = SavedProject(
            id: UUID(),
            title: normalizedTitle,
            iconSystemName: iconSystemName,
            iconColorName: iconColorName,
            createdAt: now,
            updatedAt: now
        )

        savedProjects.insert(project, at: 0)
        sortSavedProjects()
        persistSavedProjects()
    }

    func updateProject(id: UUID, title: String, iconSystemName: String, iconColorName: String) {
        let normalizedTitle = trimmed(title)
        guard !normalizedTitle.isEmpty,
              let index = savedProjects.firstIndex(where: { $0.id == id }) else {
            return
        }

        savedProjects[index].title = normalizedTitle
        savedProjects[index].iconSystemName = iconSystemName
        savedProjects[index].iconColorName = iconColorName
        savedProjects[index].updatedAt = Date()
        sortSavedProjects()
        persistSavedProjects()
    }

    func deleteProject(id: UUID) {
        guard savedProjects.contains(where: { $0.id == id }) else { return }

        for index in savedChats.indices {
            if savedChats[index].projectID == id {
                savedChats[index].projectID = nil
            }
        }

        savedProjects.removeAll(where: { $0.id == id })

        if currentProjectID == id {
            currentProjectID = nil
            persistCurrentProjectID()
        }

        persistSavedChats()
        persistSavedProjects()
    }

    func chats(inProjectID projectID: UUID) -> [SavedChat] {
        savedChats
            .filter { $0.projectID == projectID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func project(for id: UUID?) -> SavedProject? {
        guard let id else { return nil }
        return savedProjects.first(where: { $0.id == id })
    }

    func selectProject(id: UUID) {
        guard savedProjects.contains(where: { $0.id == id }) else { return }

        stopStreaming()
        currentProjectID = id
        draft = ""
        draftImageAttachments.removeAll()
        editingMessageID = nil
        errorMessage = nil

        if let latestChat = chats(inProjectID: id).first {
            currentChatID = latestChat.id
            messages = latestChat.messages
        } else {
            currentChatID = nil
            messages.removeAll()
        }

        persistCurrentProjectID()
        persistCurrentChatID()
    }

    func selectChat(id: UUID) {
        guard let selectedChat = savedChats.first(where: { $0.id == id }) else { return }

        stopStreaming()
        currentChatID = id
        currentProjectID = selectedChat.projectID
        messages = selectedChat.messages
        draft = ""
        draftImageAttachments.removeAll()
        editingMessageID = nil
        errorMessage = nil
        persistCurrentProjectID()
        persistCurrentChatID()
    }

    func renameCurrentChat(to newTitle: String) {
        guard let currentChatID else { return }
        renameChat(id: currentChatID, to: newTitle)
    }

    func renameChat(id: UUID, to newTitle: String) {
        let title = trimmed(newTitle)
        guard !title.isEmpty,
              let index = savedChats.firstIndex(where: { $0.id == id }) else {
            return
        }

        savedChats[index].title = title
        savedChats[index].updatedAt = Date()
        sortSavedChats()
        persistSavedChats()

        if let projectID = savedChats[index].projectID {
            touchProject(projectID)
        }
    }

    func deleteCurrentChat() {
        guard let currentChatID else {
            clearConversation()
            return
        }

        deleteChat(id: currentChatID)
    }

    func deleteChat(id: UUID) {
        stopStreaming()

        let deletedProjectID = savedChats.first(where: { $0.id == id })?.projectID
        savedChats.removeAll(where: { $0.id == id })

        if currentChatID == id {
            currentChatID = nil
            currentProjectID = nil
            messages.removeAll()
            draft = ""
            draftImageAttachments.removeAll()
            editingMessageID = nil
            errorMessage = nil
            persistCurrentProjectID()
            persistCurrentChatID()
        }

        persistSavedChats()

        if let deletedProjectID {
            touchProject(deletedProjectID)
        }
    }

    func assignChat(id: UUID, toProjectID projectID: UUID?) {
        guard let chatIndex = savedChats.firstIndex(where: { $0.id == id }) else { return }

        let previousProjectID = savedChats[chatIndex].projectID
        guard previousProjectID != projectID else { return }

        savedChats[chatIndex].projectID = projectID
        savedChats[chatIndex].updatedAt = Date()
        sortSavedChats()
        persistSavedChats()

        if currentChatID == id {
            currentProjectID = projectID
            persistCurrentProjectID()
        }

        if let previousProjectID {
            touchProject(previousProjectID)
        }

        if let projectID {
            touchProject(projectID)
        }
    }

    func chat(id: UUID) -> SavedChat? {
        savedChats.first(where: { $0.id == id })
    }

    private func startAssistantResponse() {
        let assistantID = UUID()
        let streamSessionID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))
        syncCurrentChat()

        let webSearchEnabledForTurn = isWebSearchEnabled
        let finalModel = resolvedModelName(webSearchEnabled: webSearchEnabledForTurn)
        let messageHistory = payloadHistory(
            assistantPlaceholderID: assistantID,
            webSearchEnabled: webSearchEnabledForTurn
        )

        let payload = AidaChatPayload(
            message_history: messageHistory,
            email: trimmed(userEmail),
            page_path: "/ios-native",
            language: "en",
            model: finalModel,
            user_id: trimmed(apiToken).isEmpty ? trimmed(userId) : nil,
            image_data_urls: messages.last(where: { $0.role == .user })?.imageAttachments.map(\.dataURL),
            web_search_enabled: webSearchEnabledForTurn ? true : nil,
            webSearchEnabled: webSearchEnabledForTurn ? true : nil
        )

        print("[AidaChat] sending model=\(finalModel) webSearchEnabled=\(webSearchEnabledForTurn)")

        let apiToken = trimmed(apiToken)

        isSending = true
        isWebSearchEnabled = false
        activeStreamSessionID = streamSessionID
        activeStreamingAssistantMessageID = assistantID
        currentStreamTask?.cancel()
        currentStreamTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await client.streamChat(payload: payload, apiToken: apiToken.isEmpty ? nil : apiToken) { [weak self] event in
                    guard let self else { return }
                    guard self.activeStreamSessionID == streamSessionID else { return }
                    if let delta = event.assistantTextDelta, !delta.isEmpty {
                        self.append(delta, toAssistantMessageWithID: assistantID)
                    }
                }

                guard activeStreamSessionID == streamSessionID else { return }
                if let index = messages.firstIndex(where: { $0.id == assistantID }), messages[index].text.isEmpty {
                    messages[index].text = "No response received."
                    syncCurrentChat()
                }
            } catch is CancellationError {
                guard activeStreamSessionID == streamSessionID else { return }
                removeAssistantPlaceholderIfEmpty(id: assistantID)
            } catch {
                guard activeStreamSessionID == streamSessionID else { return }
                removeAssistantPlaceholderIfEmpty(id: assistantID)

                if !isExpectedStreamCancellation(error) {
                    errorMessage = error.localizedDescription
                }
            }

            guard activeStreamSessionID == streamSessionID else { return }
            activeStreamingAssistantMessageID = nil
            currentStreamTask = nil
            isSending = false
        }
    }

    private func append(_ delta: String, toAssistantMessageWithID id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += delta
        syncCurrentChat()
    }

    private func removeAssistantPlaceholderIfEmpty(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if messages[index].text.isEmpty {
            messages.remove(at: index)
            syncCurrentChat()
        }
    }

    private func isExpectedStreamCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedModelName(webSearchEnabled: Bool) -> String {
        guard webSearchEnabled else { return selectedModel }
        guard !selectedModel.hasSuffix(":online") else { return selectedModel }
        return "\(selectedModel):online"
    }

    private func payloadHistory(
        assistantPlaceholderID: UUID,
        webSearchEnabled: Bool
    ) -> [AidaMessagePayload] {
        var history: [AidaMessagePayload] = []

        if let personalityInstruction = personalityInstruction() {
            history.append(
                AidaMessagePayload(
                    type: "human",
                    content: personalityInstruction,
                    image_data_urls: nil
                )
            )
        }

        if webSearchEnabled {
            history.append(
                AidaMessagePayload(
                    type: "human",
                    content: """
                    Web search is enabled for this turn. Use live web results when the request depends on current or real-time information. If search results are unavailable, say that clearly.
                    """,
                    image_data_urls: nil
                )
            )
        }

        history.append(
            contentsOf: messages
                .filter { $0.id != assistantPlaceholderID }
                .map { message in
                    AidaMessagePayload(
                        type: message.role == .user ? "human" : "ai",
                        content: message.text,
                        image_data_urls: message.role == .user ? message.imageAttachments.map(\.dataURL) : nil
                    )
                }
        )

        return history
    }

    private func personalityInstruction() -> String? {
        let preset = defaults.string(forKey: Keys.personalityPreset) ?? "Default"

        switch preset {
        case "Friendly":
            return "Respond in a warm, friendly, approachable tone while staying helpful and clear."
        case "Creative":
            return "Respond with a more imaginative, expressive, and creative tone while still being useful."
        case "Professional":
            return "Respond in a polished, professional, concise tone with clear structure."
        case "Playful":
            return "Respond in a playful, light, upbeat tone while staying helpful and easy to follow."
        case "Custom":
            let customInstructions = trimmed(
                defaults.string(forKey: Keys.customPersonalityInstructions) ?? ""
            )
            guard !customInstructions.isEmpty else { return nil }
            return "Follow these personality instructions for all assistant responses in this chat: \(customInstructions)"
        default:
            return nil
        }
    }

    private func ensureCurrentChatIfNeeded(withFirstUserMessage firstMessage: String) {
        guard currentChatID == nil else { return }

        let chatID = UUID()
        currentChatID = chatID
        savedChats.insert(
            SavedChat(
                id: chatID,
                title: defaultTitle(for: firstMessage),
                messages: [],
                updatedAt: Date(),
                projectID: nil
            ),
            at: 0
        )
        persistSavedChats()
        persistCurrentChatID()
    }

    private func syncCurrentChat() {
        guard let currentChatID else { return }

        let existingProjectID = savedChats.first(where: { $0.id == currentChatID })?.projectID

        let snapshot = SavedChat(
            id: currentChatID,
            title: savedChats.first(where: { $0.id == currentChatID })?.title ?? inferredTitle(),
            messages: messages,
            updatedAt: Date(),
            projectID: existingProjectID
        )

        if let index = savedChats.firstIndex(where: { $0.id == currentChatID }) {
            savedChats[index] = snapshot
        } else {
            savedChats.insert(snapshot, at: 0)
        }

        sortSavedChats()
        persistSavedChats()
        persistCurrentChatID()

        if let existingProjectID {
            touchProject(existingProjectID)
        }
    }

    private func touchProject(_ projectID: UUID) {
        guard let index = savedProjects.firstIndex(where: { $0.id == projectID }) else { return }
        savedProjects[index].updatedAt = Date()
        sortSavedProjects()
        persistSavedProjects()
        persistCurrentProjectID()
    }

    private func inferredTitle() -> String {
        if let firstUserMessage = messages.first(where: { $0.role == .user })?.text,
           !trimmed(firstUserMessage).isEmpty {
            return defaultTitle(for: firstUserMessage)
        }

        return "New Chat"
    }

    private func defaultTitle(for text: String) -> String {
        let normalized = trimmed(text)
        guard !normalized.isEmpty else { return "New Chat" }

        if normalized.count <= 36 {
            return normalized
        }

        let cutoffIndex = normalized.index(normalized.startIndex, offsetBy: 36)
        return "\(normalized[..<cutoffIndex])…"
    }

    private func sortSavedChats() {
        savedChats.sort { $0.updatedAt > $1.updatedAt }
    }

    private func sortSavedProjects() {
        savedProjects.sort { $0.updatedAt > $1.updatedAt }
    }

    private func persistSavedChats() {
        guard let data = try? JSONEncoder().encode(savedChats) else { return }
        defaults.set(data, forKey: Keys.savedChats)
    }

    private func persistSavedProjects() {
        guard let data = try? JSONEncoder().encode(savedProjects) else { return }
        defaults.set(data, forKey: Keys.savedProjects)
    }

    private func persistCurrentChatID() {
        defaults.set(currentChatID?.uuidString, forKey: Keys.currentChatID)
    }

    private func persistCurrentProjectID() {
        defaults.set(currentProjectID?.uuidString, forKey: Keys.currentProjectID)
    }

    private static func loadSavedChats(from defaults: UserDefaults) -> [SavedChat] {
        guard let data = defaults.data(forKey: Keys.savedChats),
              let chats = try? JSONDecoder().decode([SavedChat].self, from: data) else {
            return []
        }

        return chats.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func loadSavedProjects(from defaults: UserDefaults) -> [SavedProject] {
        guard let data = defaults.data(forKey: Keys.savedProjects),
              let projects = try? JSONDecoder().decode([SavedProject].self, from: data) else {
            return []
        }

        return projects.sorted { $0.updatedAt > $1.updatedAt }
    }
}

private extension ChatImageAttachment {
    static func prepare(from imageImport: DraftImageImport) -> ChatImageAttachment? {
        guard let image = UIImage(data: imageImport.data) else { return nil }

        let resizedImage = image.resizedForChatUpload(maxDimension: 1280)
        guard let jpegData = resizedImage.jpegData(compressionQuality: 0.82) else { return nil }

        let trimmedName = imageImport.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Photo" : trimmedName
        let lowercasedName = resolvedName.lowercased()
        let hasImageExtension = lowercasedName.hasSuffix(".jpg")
            || lowercasedName.hasSuffix(".jpeg")
            || lowercasedName.hasSuffix(".png")
            || lowercasedName.hasSuffix(".heic")

        return ChatImageAttachment(
            name: hasImageExtension ? resolvedName : "\(resolvedName).jpg",
            mimeType: "image/jpeg",
            dataURL: "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        )
    }
}

private extension UIImage {
    func resizedForChatUpload(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else { return self }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)

        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
