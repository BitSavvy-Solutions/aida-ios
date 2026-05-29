import SwiftUI
import UIKit

private enum ThemeAppearanceOption: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

private enum AccentColorOption: String, CaseIterable, Identifiable {
    case defaultTone
    case blue
    case green
    case yellow
    case pink
    case orange
    case purple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultTone:
            return "Default"
        case .blue:
            return "Blue"
        case .green:
            return "Green"
        case .yellow:
            return "Yellow"
        case .pink:
            return "Pink"
        case .orange:
            return "Orange"
        case .purple:
            return "Purple"
        }
    }

    var color: Color {
        switch self {
        case .defaultTone:
            return Color(uiColor: .systemBlue)
        case .blue:
            return .blue
        case .green:
            return .green
        case .yellow:
            return .yellow
        case .pink:
            return .pink
        case .orange:
            return .orange
        case .purple:
            return .purple
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var speechInput = SpeechInputManager()
    @Environment(\.colorScheme) private var systemColorScheme
    @FocusState private var inputFocused: Bool
    @State private var draftBeforeRecording = ""
    @State private var isSideMenuPresented = false
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var showingRenamePrompt = false
    @State private var renameDraft = ""
    @State private var collapsedHistorySections: Set<String> = []
    @State private var isAttachmentMenuPresented = false
    @AppStorage("aida-theme-appearance") private var themeAppearanceRaw = ThemeAppearanceOption.system.rawValue
    @AppStorage("aida-accent-color") private var accentColorRaw = AccentColorOption.defaultTone.rawValue
    @AppStorage("aida-personality-preset") private var personalityPreset = "Default"
    @AppStorage("aida-custom-personality-instructions") private var customPersonalityInstructions = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                VStack(spacing: 0) {
                    chatTranscript
                    composer
                }
                .background(Color(.systemGroupedBackground))
                .disabled(isSideMenuPresented)

                if isSideMenuPresented {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                isSideMenuPresented = false
                            }
                        }

                    sideMenu
                        .transition(.move(edge: .leading))
                        .zIndex(1)
                }

                if let toastMessage {
                    toastView(message: toastMessage)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .tint(appAccentColor)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Group {
                        if !isSideMenuPresented {
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    isSideMenuPresented.toggle()
                                }
                            } label: {
                                menuButtonIcon
                            }
                            .accessibilityLabel("Open menu")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    topRightChatControl
                }
            }
        }
        .preferredColorScheme(themeAppearance.preferredColorScheme)
        .tint(appAccentColor)
        .sheet(isPresented: $viewModel.showingSettings) {
            SettingsView(
                viewModel: viewModel,
                personalityPreset: $personalityPreset,
                customPersonalityInstructions: $customPersonalityInstructions,
                themeAppearance: Binding(
                    get: { themeAppearance },
                    set: { themeAppearanceRaw = $0.rawValue }
                ),
                accentColor: Binding(
                    get: { accentColorOption },
                    set: { accentColorRaw = $0.rawValue }
                )
            )
        }
        .onChange(of: speechInput.transcript) { _, newValue in
            let base = draftBeforeRecording.trimmingCharacters(in: .whitespacesAndNewlines)
            let partial = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

            if partial.isEmpty {
                viewModel.draft = draftBeforeRecording
            } else if base.isEmpty {
                viewModel.draft = partial
            } else {
                viewModel.draft = "\(base) \(partial)"
            }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil || speechInput.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.errorMessage = nil
                    speechInput.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
                speechInput.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? speechInput.errorMessage ?? "Unknown error.")
        }
        .alert("Rename Chat", isPresented: $showingRenamePrompt) {
            TextField("Chat name", text: $renameDraft)

            Button("Cancel", role: .cancel) {}

            Button("Save") {
                viewModel.renameCurrentChat(to: renameDraft)
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a new name for this chat.")
        }
    }

    private var themeAppearance: ThemeAppearanceOption {
        ThemeAppearanceOption(rawValue: themeAppearanceRaw) ?? .system
    }

    private var accentColorOption: AccentColorOption {
        AccentColorOption(rawValue: accentColorRaw) ?? .defaultTone
    }

    private var appAccentColor: Color {
        accentColorOption.color
    }

    private var effectiveColorScheme: ColorScheme {
        themeAppearance.preferredColorScheme ?? systemColorScheme
    }

    private var menuButtonIcon: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule()
                .frame(width: 22, height: 4)
            Capsule()
                .frame(width: 16, height: 4)
            Capsule()
                .frame(width: 9, height: 4)
        }
        .foregroundStyle(effectiveColorScheme == .dark ? .white : .primary)
        .frame(width: 28, height: 22, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var newChatButtonIcon: some View {
        Image(systemName: "plus")
            .font(.system(size: 20, weight: .regular))
    }

    private var topRightChatControl: some View {
        Group {
            if viewModel.hasStartedChat {
                HStack(spacing: 0) {
                    Button {
                        viewModel.clearConversation()
                    } label: {
                        newChatButtonIcon
                            .frame(width: 42, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New chat")

                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 18)

                    Menu {
                        Button("Rename") {
                            renameDraft = viewModel.currentChatTitle
                            showingRenamePrompt = true
                        }

                        Button("Delete", role: .destructive) {
                            viewModel.deleteCurrentChat()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .rotationEffect(.degrees(90))
                            .frame(width: 42, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Chat actions")
                }
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            } else {
                Button {
                    viewModel.clearConversation()
                } label: {
                    newChatButtonIcon
                }
                .accessibilityLabel("New chat")
            }
        }
    }

    private var sideMenu: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text("Aida")
                        .font(.title.weight(.bold))
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(appAccentColor)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(historySections) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    historySectionHeader(section)

                                    if !collapsedHistorySections.contains(section.id) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(section.chats) { chat in
                                                chatRow(chat)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }

                Spacer()

                HStack {
                    Button {
                        isSideMenuPresented = false
                        viewModel.showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 42, height: 42)
                            .background(
                                Circle()
                                    .fill(Color(.tertiarySystemFill))
                            )
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")

                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, proxy.safeAreaInsets.top + 60)
            .padding(.bottom, 20)
            .frame(width: 280, height: proxy.size.height, alignment: .topLeading)
            .background(Color(.secondarySystemBackground))
            .shadow(color: .black.opacity(0.14), radius: 20, x: 8, y: 0)
        }
        .frame(width: 280)
        .ignoresSafeArea(edges: .top)
    }

    private var historySections: [ChatHistorySection] {
        let chats = viewModel.savedChats
        guard !chats.isEmpty else { return [] }

        var sections: [ChatHistorySection] = []
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfLastWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfToday) ?? startOfToday

        let recents = Array(chats.prefix(6))
        if !recents.isEmpty {
            sections.append(ChatHistorySection(id: "recents", title: "Recents", chats: recents))
        }

        let yesterdayChats = chats.filter { calendar.isDateInYesterday($0.updatedAt) }
        if !yesterdayChats.isEmpty {
            sections.append(ChatHistorySection(id: "yesterday", title: "Yesterday", chats: yesterdayChats))
        }

        let lastWeekChats = chats.filter {
            let date = $0.updatedAt
            return date >= startOfLastWeek && date < startOfYesterday
        }
        if !lastWeekChats.isEmpty {
            sections.append(ChatHistorySection(id: "last-week", title: "Last Week", chats: lastWeekChats))
        }

        let lastMonthChats = chats.filter {
            let date = $0.updatedAt
            return date >= startOfLastMonth && date < startOfLastWeek
        }
        if !lastMonthChats.isEmpty {
            sections.append(ChatHistorySection(id: "last-month", title: "Last Month", chats: lastMonthChats))
        }

        let olderChats = chats.filter { $0.updatedAt < startOfLastMonth }
        let groupedOlderChats = Dictionary(grouping: olderChats) { chat in
            calendar.startOfDay(for: chat.updatedAt)
        }

        let olderSectionDates = groupedOlderChats.keys.sorted(by: >)
        for date in olderSectionDates {
            guard let groupedChats = groupedOlderChats[date], !groupedChats.isEmpty else { continue }
            sections.append(
                ChatHistorySection(
                    id: "date-\(date.timeIntervalSince1970)",
                    title: historyDateFormatter.string(from: date),
                    chats: groupedChats
                )
            )
        }

        return sections
    }

    private func historySectionHeader(_ section: ChatHistorySection) -> some View {
        Button {
            if collapsedHistorySections.contains(section.id) {
                collapsedHistorySections.remove(section.id)
            } else {
                collapsedHistorySections.insert(section.id)
            }
        } label: {
            HStack(spacing: 8) {
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsedHistorySections.contains(section.id) ? -90 : 0))
            }
        }
        .buttonStyle(.plain)
    }

    private func chatRow(_ chat: SavedChat) -> some View {
        Button {
            viewModel.selectChat(id: chat.id)
            withAnimation(.easeInOut(duration: 0.22)) {
                isSideMenuPresented = false
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.currentChatID == chat.id ? .white : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(viewModel.currentChatID == chat.id ? .white : .primary)

                    Text(historyTimeFormatter.string(from: chat.updatedAt))
                        .font(.caption)
                        .foregroundStyle(viewModel.currentChatID == chat.id ? .white.opacity(0.82) : .secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(viewModel.currentChatID == chat.id ? appAccentColor : Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
    }

    private var chatTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(
                            message: message,
                            onCopyUserMessage: {
                                UIPasteboard.general.string = message.text
                                presentToast("Message copied")
                            },
                            onEditUserMessage: {
                                guard viewModel.beginEditing(messageID: message.id) else { return }
                                inputFocused = true
                            },
                            onRegenerateAssistantMessage: {
                                _ = viewModel.regenerateAssistantMessage(messageID: message.id)
                            },
                            accentColor: appAccentColor
                        )
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onTapGesture {
                dismissAttachmentMenu()
            }
            .onChange(of: viewModel.messages) { _, messages in
                guard let lastID = messages.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if speechInput.isRecording {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Listening…")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            VStack(spacing: 14) {
                if viewModel.editingMessageID != nil {
                    editingBanner
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }

                TextField("Chat with Aida", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, viewModel.editingMessageID == nil ? 18 : 4)
                    .padding(.bottom, 10)
                    .focused($inputFocused)
                    .lineLimit(3 ... 8)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            dismissAttachmentMenu()
                        }
                    )

                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: 10) {
                        plusAccessory
                        webSearchButton
                        bottomModelMenu
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        micButton
                        sendButton
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 1)
        .background(.bar)
    }

    private var editingBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Editing this message will restart the conversation from this point.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            Button {
                viewModel.cancelEditing()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color(.tertiarySystemFill))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel editing")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }

    private func presentToast(_ message: String, duration: Double = 1.8) {
        toastDismissTask?.cancel()

        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }

        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func dismissAttachmentMenu() {
        guard isAttachmentMenuPresented else { return }

        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            isAttachmentMenuPresented = false
        }
    }

    private func toastView(message: String) -> some View {
        VStack {
            Spacer()

            Text(message)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.82))
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 108)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var bottomModelMenu: some View {
        Menu {
            Section("Text Models") {
                Picker("Model", selection: $viewModel.selectedModel) {
                    ForEach(ModelOption.defaults) { model in
                        Text(model.label).tag(model.value)
                    }
                }
            }
            .onChange(of: viewModel.selectedModel) { _, _ in
                viewModel.persistSettings()
            }
        } label: {
            HStack(spacing: 8) {
                Text(viewModel.selectedModelLabel)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissAttachmentMenu()
            }
        )
    }

    private var webSearchButton: some View {
        Button {
            dismissAttachmentMenu()
            viewModel.isWebSearchEnabled.toggle()
        } label: {
            Image(systemName: "globe")
                .font(.subheadline.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(viewModel.isWebSearchEnabled ? appAccentColor : Color(.tertiarySystemFill))
                )
                .foregroundStyle(viewModel.isWebSearchEnabled ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle web search")
    }

    private var plusAccessory: some View {
        Button {
            inputFocused = false
            withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                isAttachmentMenuPresented.toggle()
            }
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.semibold))
                .rotationEffect(.degrees(isAttachmentMenuPresented ? 45 : 0))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color(.tertiarySystemFill))
                )
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomLeading) {
            if isAttachmentMenuPresented {
                attachmentMenu
                    .offset(x: -4, y: -30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .zIndex(isAttachmentMenuPresented ? 1 : 0)
        .accessibilityLabel("Open attachments")
    }

    private var attachmentMenu: some View {
        VStack(alignment: .leading, spacing: 10) {
            attachmentMenuButton(title: "Camera", systemImage: "camera")
            attachmentMenuButton(title: "Photos", systemImage: "photo.on.rectangle")
            attachmentMenuButton(title: "Files", systemImage: "doc")
            attachmentMenuButton(title: "URL", systemImage: "link")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
    }

    private func attachmentMenuButton(title: String, systemImage: String) -> some View {
        Button {
            dismissAttachmentMenu()
            presentToast("\(title) coming soon")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color(.tertiarySystemFill))
                    )

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: 170, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var micButton: some View {
        Button {
            dismissAttachmentMenu()
            Task {
                if speechInput.isRecording {
                    speechInput.stopRecording()
                } else {
                    draftBeforeRecording = viewModel.draft
                    speechInput.resetTranscript()
                    await speechInput.startRecording()
                }
            }
        } label: {
            Image(systemName: speechInput.isRecording ? "stop.fill" : "mic.fill")
                .font(.title3.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(speechInput.isRecording ? Color.red : Color(.tertiarySystemFill))
                )
                .foregroundStyle(speechInput.isRecording ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var sendButton: some View {
        Button {
            dismissAttachmentMenu()
            if viewModel.isSending {
                viewModel.stopStreaming()
            } else {
                inputFocused = false
                viewModel.sendMessage()
            }
        } label: {
            Image(systemName: viewModel.isSending ? "stop.fill" : "arrow.up")
                .font(.title3.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(canSend ? appAccentColor : Color(.systemGray4))
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !viewModel.isSending)
    }

    private var canSend: Bool {
        !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.hasRequiredIdentity
    }
}

private struct ChatHistorySection: Identifiable {
    let id: String
    let title: String
    let chats: [SavedChat]
}

private let historyDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .none
    return formatter
}()

private let historyTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

private struct MessageBubble: View {
    let message: ChatMessage
    let onCopyUserMessage: () -> Void
    let onEditUserMessage: () -> Void
    let onRegenerateAssistantMessage: () -> Void
    let accentColor: Color
    @State private var copied = false

    var body: some View {
        HStack {
            if message.role == .assistant {
                VStack(alignment: .leading, spacing: 6) {
                    bubble
                    assistantActions
                }
                Spacer(minLength: 50)
            } else {
                Spacer(minLength: 50)
                bubble
            }
        }
    }

    private var bubble: some View {
        Group {
            if message.role == .assistant {
                renderedAssistantText
            } else {
                Text(message.text.isEmpty ? "…" : message.text)
            }
        }
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(message.role == .assistant ? Color(.secondarySystemBackground) : accentColor)
            )
            .foregroundStyle(message.role == .assistant ? Color.primary : Color.white)
            .contextMenu {
                if message.role == .user {
                    Button {
                        onCopyUserMessage()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button {
                        onEditUserMessage()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }
    }

    private var renderedAssistantText: some View {
        Group {
            if message.text.isEmpty {
                Text("…")
            } else {
                Text(verbatim: displayAssistantText)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var displayAssistantText: String {
        message.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(
                of: #"(?m)^\s*---+\s*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?m)^#{1,6}\s*(.+)$"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\*\*(.*?)\*\*"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"__(.*?)__"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?m)^-\s+"#,
                with: "• ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"`([^`]*)`"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(of: "  \n", with: "\n")
            .replacingOccurrences(
                of: #"\n{3,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var assistantActions: some View {
        if message.role == .assistant && !message.text.isEmpty {
            HStack(spacing: 16) {
                Button {
                    UIPasteboard.general.string = message.text
                    copied = true

                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
                .accessibilityLabel(copied ? "Copied" : "Copy")

                Button {
                    onRegenerateAssistantMessage()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Image(systemName: "sparkles")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Regenerate")
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var personalityPreset: String
    @Binding var customPersonalityInstructions: String
    @Binding var themeAppearance: ThemeAppearanceOption
    @Binding var accentColor: AccentColorOption
    @Environment(\.dismiss) private var dismiss

    private let personalityOptions = [
        "Default",
        "Friendly",
        "Creative",
        "Professional",
        "Playful",
        "Custom"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Theme")
                            .font(.title3.weight(.semibold))

                        settingsCard {
                            Menu {
                                ForEach(ThemeAppearanceOption.allCases) { option in
                                    Button {
                                        themeAppearance = option
                                    } label: {
                                        HStack {
                                            if themeAppearance == option {
                                                Image(systemName: "checkmark")
                                            }
                                            Text(option.title)
                                        }
                                    }
                                }
                            } label: {
                                settingsRow(
                                    icon: "moon",
                                    title: "Appearance",
                                    trailingText: themeAppearance.title
                                )
                            }
                            .buttonStyle(.plain)

                            settingsDivider

                            Menu {
                                ForEach(AccentColorOption.allCases) { option in
                                    Button {
                                        accentColor = option
                                    } label: {
                                        HStack {
                                            if accentColor == option {
                                                Image(systemName: "checkmark")
                                            }
                                            Circle()
                                                .fill(option.color)
                                                .frame(width: 14, height: 14)
                                            Text(option.title)
                                        }
                                    }
                                }
                            } label: {
                                settingsRow(
                                    icon: "paintpalette",
                                    title: "Accent color",
                                    trailingText: accentColor.title,
                                    trailingColor: accentColor.color
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Assistant")
                            .font(.title3.weight(.semibold))

                        settingsCard {
                            Menu {
                                ForEach(personalityOptions, id: \.self) { option in
                                    Button {
                                        personalityPreset = option
                                    } label: {
                                        HStack {
                                            if personalityPreset == option {
                                                Image(systemName: "checkmark")
                                            }
                                            Text(option)
                                        }
                                    }
                                }
                            } label: {
                                settingsRow(
                                    icon: "sparkles",
                                    title: "Personality",
                                    trailingText: personalityPreset
                                )
                            }
                            .buttonStyle(.plain)

                            if personalityPreset == "Custom" {
                                settingsDivider

                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Custom instructions")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)

                                    TextEditor(text: $customPersonalityInstructions)
                                        .frame(minHeight: 110)
                                        .scrollContentBackground(.hidden)
                                        .padding(10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .fill(Color(.tertiarySystemFill))
                                        )
                                }
                                .padding(.horizontal, 18)
                                .padding(.top, 16)
                                .padding(.bottom, 18)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Identity")
                            .font(.title3.weight(.semibold))

                        settingsCard {
                            VStack(spacing: 0) {
                                settingsTextField(
                                    "Email",
                                    text: $viewModel.userEmail,
                                    keyboardType: .emailAddress
                                )
                                settingsDivider
                                settingsTextField("User ID", text: $viewModel.userId)
                                settingsDivider
                                SecureField("API Token (optional)", text: $viewModel.apiToken)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        Text("The backend requires an email and either a user ID or an API token.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        viewModel.persistSettings()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var settingsDivider: some View {
        Divider()
            .padding(.leading, 60)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func settingsTextField(
        _ title: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default
    ) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboardType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsRow(
        icon: String,
        title: String,
        trailingText: String,
        trailingColor: Color? = nil
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .frame(width: 28)

            Text(title)
                .font(.title3)

            Spacer(minLength: 12)

            if let trailingColor {
                Circle()
                    .fill(trailingColor)
                    .frame(width: 16, height: 16)
            }

            Text(trailingText)
                .font(.title3)
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.up.chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .contentShape(Rectangle())
    }
}
