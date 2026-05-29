import Combine
import Foundation

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

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct SavedChat: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
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
    @Published private(set) var editingMessageID: UUID?
    @Published private(set) var savedChats: [SavedChat]
    @Published private(set) var currentChatID: UUID?

    private let client = AidaAPIClient()
    private var currentStreamTask: Task<Void, Never>?
    private let defaults: UserDefaults

    private enum Keys {
        static let selectedModel = "native-selected-model"
        static let userEmail = "native-user-email"
        static let userId = "native-user-id"
        static let apiToken = "native-api-token"
        static let savedChats = "native-saved-chats"
        static let currentChatID = "native-current-chat-id"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedModel = defaults.string(forKey: Keys.selectedModel) ?? ModelOption.defaults[0].value
        self.userEmail = defaults.string(forKey: Keys.userEmail) ?? ""
        self.userId = defaults.string(forKey: Keys.userId) ?? ""
        self.apiToken = defaults.string(forKey: Keys.apiToken) ?? ""
        self.savedChats = Self.loadSavedChats(from: defaults)
        self.currentChatID = defaults.string(forKey: Keys.currentChatID).flatMap(UUID.init(uuidString:))

        if let currentChatID,
           let existingChat = savedChats.first(where: { $0.id == currentChatID }) {
            self.messages = existingChat.messages
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
        guard !text.isEmpty else { return }
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

        ensureCurrentChatIfNeeded(withFirstUserMessage: text)

        let userMessage = ChatMessage(role: .user, text: text)
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

    private func startAssistantResponse() {
        let assistantID = UUID()
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
            web_search_enabled: webSearchEnabledForTurn ? true : nil,
            webSearchEnabled: webSearchEnabledForTurn ? true : nil
        )

        print("[AidaChat] sending model=\(finalModel) webSearchEnabled=\(webSearchEnabledForTurn)")

        let apiToken = trimmed(apiToken)

        isSending = true
        isWebSearchEnabled = false
        currentStreamTask?.cancel()
        currentStreamTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await client.streamChat(payload: payload, apiToken: apiToken.isEmpty ? nil : apiToken) { [weak self] event in
                    guard let self else { return }
                    if let delta = event.assistantTextDelta, !delta.isEmpty {
                        self.append(delta, toAssistantMessageWithID: assistantID)
                    }
                }

                if let index = messages.firstIndex(where: { $0.id == assistantID }), messages[index].text.isEmpty {
                    messages[index].text = "No response received."
                    syncCurrentChat()
                }
            } catch is CancellationError {
                removeAssistantPlaceholderIfEmpty(id: assistantID)
            } catch {
                removeAssistantPlaceholderIfEmpty(id: assistantID)
                errorMessage = error.localizedDescription
            }

            isSending = false
        }
    }

    func stopStreaming() {
        currentStreamTask?.cancel()
        currentStreamTask = nil
        isSending = false
    }

    func clearConversation() {
        stopStreaming()
        syncCurrentChat()
        currentChatID = nil
        messages.removeAll()
        errorMessage = nil
        editingMessageID = nil
        draft = ""
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
        editingMessageID = messageID
        errorMessage = nil
        return true
    }

    func cancelEditing() {
        editingMessageID = nil
    }

    func selectChat(id: UUID) {
        guard let selectedChat = savedChats.first(where: { $0.id == id }) else { return }

        stopStreaming()
        currentChatID = id
        messages = selectedChat.messages
        draft = ""
        editingMessageID = nil
        errorMessage = nil
        persistCurrentChatID()
    }

    func renameCurrentChat(to newTitle: String) {
        guard let currentChatID else { return }

        let title = trimmed(newTitle)
        guard !title.isEmpty,
              let index = savedChats.firstIndex(where: { $0.id == currentChatID }) else {
            return
        }

        savedChats[index].title = title
        savedChats[index].updatedAt = Date()
        sortSavedChats()
        persistSavedChats()
    }

    func deleteCurrentChat() {
        guard let currentChatID else {
            clearConversation()
            return
        }

        stopStreaming()
        savedChats.removeAll(where: { $0.id == currentChatID })
        self.currentChatID = nil
        messages.removeAll()
        draft = ""
        editingMessageID = nil
        errorMessage = nil
        persistSavedChats()
        persistCurrentChatID()
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

        if webSearchEnabled {
            history.append(
                AidaMessagePayload(
                    type: "human",
                    content: """
                    Web search is enabled for this turn. Use live web results when the request depends on current or real-time information. If search results are unavailable, say that clearly.
                    """
                )
            )
        }

        history.append(
            contentsOf: messages
                .filter { $0.id != assistantPlaceholderID }
                .map { message in
                    AidaMessagePayload(
                        type: message.role == .user ? "human" : "ai",
                        content: message.text
                    )
                }
        )

        return history
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
                updatedAt: Date()
            ),
            at: 0
        )
        persistSavedChats()
        persistCurrentChatID()
    }

    private func syncCurrentChat() {
        guard let currentChatID else { return }

        let snapshot = SavedChat(
            id: currentChatID,
            title: savedChats.first(where: { $0.id == currentChatID })?.title ?? inferredTitle(),
            messages: messages,
            updatedAt: Date()
        )

        if let index = savedChats.firstIndex(where: { $0.id == currentChatID }) {
            savedChats[index] = snapshot
        } else {
            savedChats.insert(snapshot, at: 0)
        }

        sortSavedChats()
        persistSavedChats()
        persistCurrentChatID()
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

    private func persistSavedChats() {
        guard let data = try? JSONEncoder().encode(savedChats) else { return }
        defaults.set(data, forKey: Keys.savedChats)
    }

    private func persistCurrentChatID() {
        defaults.set(currentChatID?.uuidString, forKey: Keys.currentChatID)
    }

    private static func loadSavedChats(from defaults: UserDefaults) -> [SavedChat] {
        guard let data = defaults.data(forKey: Keys.savedChats),
              let chats = try? JSONDecoder().decode([SavedChat].self, from: data) else {
            return []
        }

        return chats.sorted { $0.updatedAt > $1.updatedAt }
    }
}
