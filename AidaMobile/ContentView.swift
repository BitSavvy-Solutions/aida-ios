import AVFoundation
import Combine
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @StateObject private var assistantSpeech = AssistantSpeechManager()
    @Environment(\.colorScheme) private var systemColorScheme
    @FocusState private var inputFocused: Bool
    @State private var draftBeforeRecording = ""
    @State private var isSideMenuPresented = false
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var showingRenamePrompt = false
    @State private var showingNewProjectSheet = false
    @State private var showingProjectEditor = false
    @State private var renameDraft = ""
    @State private var renameTargetChatID: UUID?
    @State private var editingProjectID: UUID?
    @State private var collapsedHistorySections: Set<String> = []
    @State private var knownProjectCollapseKeys: Set<String> = []
    @State private var hoveredProjectDropID: UUID?
    @State private var isAttachmentMenuPresented = false
    @State private var isCameraPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isImportingPhotos = false
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
        .sheet(isPresented: $showingNewProjectSheet) {
            NewProjectSheet(accentColor: appAccentColor) { title, iconSystemName, iconColorName in
                viewModel.createProject(
                    title: title,
                    iconSystemName: iconSystemName,
                    iconColorName: iconColorName
                )
            }
        }
        .sheet(isPresented: $showingProjectEditor, onDismiss: {
            editingProjectID = nil
        }) {
            if let editingProjectID,
               let project = viewModel.project(for: editingProjectID) {
                EditProjectSheet(
                    project: project,
                    projectChats: viewModel.chats(inProjectID: project.id),
                    accentColor: appAccentColor,
                    onSave: { title, iconSystemName, iconColorName in
                        viewModel.updateProject(
                            id: project.id,
                            title: title,
                            iconSystemName: iconSystemName,
                            iconColorName: iconColorName
                        )
                    },
                    onRemoveChat: { chatID in
                        viewModel.assignChat(id: chatID, toProjectID: nil)
                    }
                )
            } else {
                Color.clear
                    .presentationDetents([.height(1)])
                    .onAppear {
                        showingProjectEditor = false
                }
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraCaptureView(isPresented: $isCameraPresented) { image in
                importCapturedPhoto(image)
            }
            .ignoresSafeArea()
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
        .onAppear {
            syncProjectCollapseState(with: viewModel.savedProjects)
        }
        .onChange(of: viewModel.savedProjects) { _, projects in
            syncProjectCollapseState(with: projects)
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }

            Task {
                await importSelectedPhotos(items)
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

            Button("Cancel", role: .cancel) {
                renameTargetChatID = nil
            }

            Button("Save") {
                if let renameTargetChatID {
                    viewModel.renameChat(id: renameTargetChatID, to: renameDraft)
                }
                renameTargetChatID = nil
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a new name for this chat.")
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotoItems,
            maxSelectionCount: nil,
            matching: .images,
            preferredItemEncoding: .automatic
        )
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
                        Button {
                            renameDraft = viewModel.currentChatTitle
                            renameTargetChatID = viewModel.currentChatID
                            showingRenamePrompt = true
                        } label: {
                            Label("Rename Chat", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            viewModel.deleteCurrentChat()
                        } label: {
                            destructiveTrashMenuLabel("Delete Chat")
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
                        VStack(alignment: .leading, spacing: 22) {
                            projectsSection

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

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Projects")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                showingNewProjectSheet = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "folder.badge.plus")
                        .font(.headline.weight(.medium))
                        .frame(width: 22)

                    Text("New Project")
                        .font(.subheadline.weight(.medium))

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Project")

            if !viewModel.savedProjects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.savedProjects) { project in
                        projectRow(project)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.top, 6)
    }

    private func projectRow(_ project: SavedProject) -> some View {
        let projectChats = viewModel.chats(inProjectID: project.id)
        let isExpanded = collapsedHistorySections.contains(projectCollapseKey(project.id)) == false
        let isSelected = viewModel.currentProjectID == project.id
        let isDropTargeted = hoveredProjectDropID == project.id

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isExpanded {
                    collapsedHistorySections.insert(projectCollapseKey(project.id))
                } else {
                    collapsedHistorySections.remove(projectCollapseKey(project.id))
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: project.iconSystemName)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(projectIconColor(named: project.iconColorName))

                    Text(project.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)

                    if !projectChats.isEmpty {
                        Text("\(projectChats.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            isDropTargeted
                                ? appAccentColor.opacity(0.22)
                                : (isSelected ? appAccentColor.opacity(0.16) : Color(.tertiarySystemFill))
                        )
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    editingProjectID = project.id
                    showingProjectEditor = true
                } label: {
                    Label("Edit Project", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    if editingProjectID == project.id {
                        editingProjectID = nil
                        showingProjectEditor = false
                    }
                    if viewModel.currentProjectID == project.id {
                        collapsedHistorySections.insert(projectCollapseKey(project.id))
                    }
                    viewModel.deleteProject(id: project.id)
                } label: {
                    destructiveTrashMenuLabel("Delete Project")
                }
            }

            if isExpanded {
                if projectChats.isEmpty {
                    Text("No chats yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                        .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(projectChats) { chat in
                            projectChatRow(chat)
                        }
                    }
                    .padding(.leading, 10)
                }
            }
        }
        .onDrop(
            of: [UTType.text.identifier],
            delegate: SidebarProjectDropDelegate(
                projectID: project.id,
                hoveredProjectDropID: $hoveredProjectDropID,
                collapsedHistorySections: $collapsedHistorySections,
                collapseKey: projectCollapseKey(project.id),
                onAssignChat: { chatID, projectID in
                    viewModel.assignChat(id: chatID, toProjectID: projectID)
                }
            )
        )
    }

    private func projectChatRow(_ chat: SavedChat) -> some View {
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
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(viewModel.currentChatID == chat.id ? .white : .primary)

                    Text(historyTimeFormatter.string(from: chat.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(viewModel.currentChatID == chat.id ? .white.opacity(0.82) : .secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(viewModel.currentChatID == chat.id ? appAccentColor : Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            sidebarChatContextMenu(for: chat)
        }
        .onDrag {
            NSItemProvider(object: chat.id.uuidString as NSString)
        }
    }

    private var historySections: [ChatHistorySection] {
        let chats = viewModel.savedChats.filter { $0.projectID == nil }
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
        .contextMenu {
            sidebarChatContextMenu(for: chat)
        }
        .onDrag {
            NSItemProvider(object: chat.id.uuidString as NSString)
        }
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
                            onRegenerateUserMessage: {
                                _ = viewModel.regenerateFromUserMessage(messageID: message.id)
                            },
                            onSpeakAssistantMessage: {
                                assistantSpeech.toggleSpeech(for: message)
                            },
                            isSpeakingAssistantMessage: assistantSpeech.speakingMessageID == message.id,
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

                if isImportingPhotos || !viewModel.draftImageAttachments.isEmpty {
                    draftImageTray
                        .padding(.horizontal, 12)
                        .padding(.top, viewModel.editingMessageID == nil ? 12 : 0)
                }

                TextField("Chat with Aida", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, viewModel.editingMessageID == nil && viewModel.draftImageAttachments.isEmpty && !isImportingPhotos ? 18 : 4)
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

    private func importSelectedPhotos(_ items: [PhotosPickerItem]) async {
        isImportingPhotos = true
        defer {
            isImportingPhotos = false
            selectedPhotoItems = []
        }

        var imports: [DraftImageImport] = []

        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }

            let contentType = item.supportedContentTypes.first
            let fileExtension = contentType?.preferredFilenameExtension ?? "jpg"

            imports.append(
                DraftImageImport(
                    data: data,
                    name: "Photo \(index + 1).\(fileExtension)"
                )
            )
        }

        if imports.isEmpty {
            presentToast("Couldn't load the selected photo")
            return
        }

        viewModel.addDraftImageImports(imports)
        inputFocused = true
    }

    private func startCameraCapture() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            presentToast("Camera is unavailable on this device")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isCameraPresented = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        isCameraPresented = true
                    } else {
                        presentToast("Allow camera access in Settings")
                    }
                }
            }
        case .denied, .restricted:
            presentToast("Allow camera access in Settings")
        @unknown default:
            presentToast("Camera is unavailable right now")
        }
    }

    private func importCapturedPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            presentToast("Couldn't process the captured photo")
            return
        }

        let previousAttachmentCount = viewModel.draftImageAttachments.count
        viewModel.addDraftImageImports([
            DraftImageImport(
                data: data,
                name: "Camera Photo.jpg"
            )
        ])

        guard viewModel.draftImageAttachments.count > previousAttachmentCount else {
            presentToast("Couldn't process the captured photo")
            return
        }

        inputFocused = true
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

    private var draftImageTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if isImportingPhotos {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading photos…")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )
                }

                ForEach(viewModel.draftImageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        imageAttachmentThumbnail(attachment, size: CGSize(width: 92, height: 92))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Button {
                            viewModel.removeDraftImageAttachment(id: attachment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.black.opacity(0.72)))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.vertical, 2)
        }
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
            attachmentMenuButton(title: "Camera", systemImage: "camera") {
                startCameraCapture()
            }
            attachmentMenuButton(title: "Photos", systemImage: "photo.on.rectangle") {
                isPhotoPickerPresented = true
            }
            attachmentMenuButton(title: "Files", systemImage: "doc") {
                presentToast("Files coming soon")
            }
            attachmentMenuButton(title: "URL", systemImage: "link") {
                presentToast("URL coming soon")
            }
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

    private func attachmentMenuButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            dismissAttachmentMenu()
            action()
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
        (
            !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !viewModel.draftImageAttachments.isEmpty
        ) && viewModel.hasRequiredIdentity
    }

    private func projectCollapseKey(_ id: UUID) -> String {
        "project-\(id.uuidString)"
    }

    private func projectIconColor(named colorName: String) -> Color {
        ProjectIconColorOption(rawValue: colorName)?.color ?? .white
    }

    private func syncProjectCollapseState(with projects: [SavedProject]) {
        let projectKeys = Set(projects.map { projectCollapseKey($0.id) })
        let newKeys = projectKeys.subtracting(knownProjectCollapseKeys)

        collapsedHistorySections.formUnion(newKeys)
        collapsedHistorySections = collapsedHistorySections.intersection(projectKeys.union(nonProjectCollapsedSectionKeys))
        knownProjectCollapseKeys = projectKeys
    }

    private var nonProjectCollapsedSectionKeys: Set<String> {
        Set(collapsedHistorySections.filter { !$0.hasPrefix("project-") })
    }

    private func destructiveTrashMenuLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .symbolRenderingMode(.monochrome)
                .foregroundColor(.red)

            Text(title)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private func sidebarChatContextMenu(for chat: SavedChat) -> some View {
        Button {
            renameDraft = chat.title
            renameTargetChatID = chat.id
            showingRenamePrompt = true
        } label: {
            Label("Rename Chat", systemImage: "pencil")
        }

        Button(role: .destructive) {
            viewModel.deleteChat(id: chat.id)
        } label: {
            destructiveTrashMenuLabel("Delete Chat")
        }

        Menu {
            if chat.projectID != nil {
                Button {
                    viewModel.assignChat(id: chat.id, toProjectID: nil)
                } label: {
                    Label("Remove from Project", systemImage: "tray.and.arrow.up")
                }
            }

            if viewModel.savedProjects.isEmpty {
                Button("No Projects Yet") {}
                    .disabled(true)
            } else {
                ForEach(viewModel.savedProjects) { project in
                    Button {
                        collapsedHistorySections.remove(projectCollapseKey(project.id))
                        viewModel.assignChat(id: chat.id, toProjectID: project.id)
                    } label: {
                        Label(project.title, systemImage: project.iconSystemName)
                    }
                }
            }
        } label: {
            Label("Add to Project", systemImage: "folder.badge.plus")
        }
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraCaptureView

        init(_ parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.isPresented = false
                return
            }

            parent.isPresented = false
            parent.onCapture(image)
        }
    }
}

private enum ProjectIconColorOption: String, CaseIterable, Identifiable {
    case white
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .white:
            return .white
        case .red:
            return Color(red: 1.0, green: 0.29, blue: 0.26)
        case .orange:
            return Color(red: 1.0, green: 0.47, blue: 0.0)
        case .yellow:
            return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .green:
            return Color(red: 0.0, green: 0.78, blue: 0.35)
        case .blue:
            return Color(red: 0.1, green: 0.53, blue: 0.98)
        case .purple:
            return Color(red: 0.63, green: 0.32, blue: 0.95)
        case .pink:
            return Color(red: 0.96, green: 0.33, blue: 0.73)
        }
    }
}

private struct ProjectSymbolOption: Identifiable, Hashable {
    let systemName: String

    var id: String { systemName }

    static let all: [ProjectSymbolOption] = [
        .init(systemName: "folder"),
        .init(systemName: "dollarsign.circle"),
        .init(systemName: "book.closed"),
        .init(systemName: "graduationcap"),
        .init(systemName: "pencil"),
        .init(systemName: "signature"),
        .init(systemName: "curlybraces"),
        .init(systemName: "terminal"),
        .init(systemName: "music.note"),
        .init(systemName: "popcorn"),
        .init(systemName: "paintbrush.pointed"),
        .init(systemName: "paintpalette"),
        .init(systemName: "stethoscope"),
        .init(systemName: "sparkles"),
        .init(systemName: "leaf"),
        .init(systemName: "briefcase"),
        .init(systemName: "chart.bar"),
        .init(systemName: "person.2"),
        .init(systemName: "waveform"),
        .init(systemName: "checklist"),
        .init(systemName: "scalemass"),
        .init(systemName: "microphone"),
        .init(systemName: "airplane"),
        .init(systemName: "globe"),
        .init(systemName: "wrench.and.screwdriver"),
        .init(systemName: "pawprint"),
        .init(systemName: "flask"),
        .init(systemName: "brain"),
        .init(systemName: "heart"),
        .init(systemName: "gift")
    ]
}

private struct NewProjectSheet: View {
    let accentColor: Color
    let onCreate: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var projectName = ""
    @State private var selectedSymbol = "folder"
    @State private var selectedColor = ProjectIconColorOption.white
    @State private var showingIconPicker = false

    private var canCreate: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("New Project")
                    .font(.title2.weight(.bold))

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.bold))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(Color(.tertiarySystemFill))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel("Close")
            }

            Text("Create a project folder to keep related chats together.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Button {
                    showingIconPicker = true
                } label: {
                    Image(systemName: selectedSymbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(selectedColor.color)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose project icon")

                TextField("Project name", text: $projectName)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.medium))
                    .focused($nameFocused)
                    .textInputAutocapitalization(.words)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )

            Button {
                onCreate(
                    projectName.trimmingCharacters(in: .whitespacesAndNewlines),
                    selectedSymbol,
                    selectedColor.rawValue
                )
                dismiss()
            } label: {
                Text("Create Project")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Capsule(style: .continuous)
                            .fill(canCreate ? accentColor : Color(.systemGray4))
                    )
                    .foregroundStyle(canCreate ? Color.white : Color(.secondaryLabel))
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)

            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.height(320)])
        .presentationCornerRadius(30)
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(.secondarySystemBackground))
        .sheet(isPresented: $showingIconPicker) {
            ProjectIconPickerSheet(
                selectedSymbol: $selectedSymbol,
                selectedColor: $selectedColor
            )
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                nameFocused = true
            }
        }
    }
}

private struct EditProjectSheet: View {
    let project: SavedProject
    let projectChats: [SavedChat]
    let accentColor: Color
    let onSave: (String, String, String) -> Void
    let onRemoveChat: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var projectName: String
    @State private var selectedSymbol: String
    @State private var selectedColor: ProjectIconColorOption
    @State private var showingIconPicker = false

    init(
        project: SavedProject,
        projectChats: [SavedChat],
        accentColor: Color,
        onSave: @escaping (String, String, String) -> Void,
        onRemoveChat: @escaping (UUID) -> Void
    ) {
        self.project = project
        self.projectChats = projectChats
        self.accentColor = accentColor
        self.onSave = onSave
        self.onRemoveChat = onRemoveChat
        _projectName = State(initialValue: project.title)
        _selectedSymbol = State(initialValue: project.iconSystemName)
        _selectedColor = State(
            initialValue: ProjectIconColorOption(rawValue: project.iconColorName) ?? .white
        )
    }

    private var canSave: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Text("Edit Project")
                            .font(.title2.weight(.bold))

                        Spacer()

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.bold))
                                .frame(width: 40, height: 40)
                                .background(
                                    Circle()
                                        .fill(Color(.tertiarySystemFill))
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Close")
                    }

                    HStack(spacing: 14) {
                        Button {
                            showingIconPicker = true
                        } label: {
                            Image(systemName: selectedSymbol)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(selectedColor.color)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color(.tertiarySystemFill))
                                )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose project icon")

                    TextField("Project name", text: $projectName)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.medium))
                            .focused($nameFocused)
                            .textInputAutocapitalization(.words)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Chats in Project")
                            .font(.headline.weight(.semibold))

                        if projectChats.isEmpty {
                            Text("No chats in this project.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(projectChats) { chat in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(chat.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        Text(historyTimeFormatter.string(from: chat.updatedAt))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button {
                                        onRemoveChat(chat.id)
                                    } label: {
                                        Text("Remove")
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(Color(.tertiarySystemFill))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.primary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                )
                            }
                        }
                    }

                    Button {
                        onSave(
                            projectName.trimmingCharacters(in: .whitespacesAndNewlines),
                            selectedSymbol,
                            selectedColor.rawValue
                        )
                        dismiss()
                    } label: {
                        Text("Save Changes")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(canSave ? accentColor : Color(.systemGray4))
                            )
                            .foregroundStyle(canSave ? Color.white : Color(.secondaryLabel))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
                .padding(24)
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(30)
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(.secondarySystemBackground))
            .sheet(isPresented: $showingIconPicker) {
                ProjectIconPickerSheet(
                    selectedSymbol: $selectedSymbol,
                    selectedColor: $selectedColor
                )
            }
            .onAppear {
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    nameFocused = true
                }
            }
        }
    }
}

private struct ProjectIconPickerSheet: View {
    @Binding var selectedSymbol: String
    @Binding var selectedColor: ProjectIconColorOption
    @Environment(\.dismiss) private var dismiss

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Choose Icon")
                    .font(.title3.weight(.bold))

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .font(.headline.weight(.semibold))
            }

            HStack {
                Spacer()

                Image(systemName: selectedSymbol)
                    .font(.system(size: 54, weight: .regular))
                    .foregroundStyle(selectedColor.color)
                    .frame(width: 108, height: 108)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )

                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(ProjectIconColorOption.allCases) { colorOption in
                        Button {
                            selectedColor = colorOption
                        } label: {
                            Circle()
                                .fill(colorOption.color)
                                .overlay {
                                    Circle()
                                        .stroke(
                                            Color.white.opacity(colorOption == .white ? 0.16 : 0),
                                            lineWidth: 2
                                        )
                                }
                                .overlay {
                                    Circle()
                                        .stroke(
                                            colorOption == selectedColor ? Color.primary : Color.clear,
                                            lineWidth: 3
                                        )
                                        .padding(2)
                                }
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 18) {
                    ForEach(ProjectSymbolOption.all) { option in
                        Button {
                            selectedSymbol = option.systemName
                        } label: {
                            Image(systemName: option.systemName)
                                .font(.system(size: 24, weight: .regular))
                                .foregroundStyle(selectedColor.color)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(
                                            selectedSymbol == option.systemName
                                                ? Color(.tertiarySystemFill)
                                                : Color.clear
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(
                                            selectedSymbol == option.systemName
                                                ? Color.primary.opacity(0.2)
                                                : Color.clear,
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(24)
        .presentationDetents([.height(520)])
        .presentationCornerRadius(32)
        .presentationBackground(Color(.secondarySystemBackground))
    }
}

private struct SidebarProjectDropDelegate: DropDelegate {
    let projectID: UUID
    @Binding var hoveredProjectDropID: UUID?
    @Binding var collapsedHistorySections: Set<String>
    let collapseKey: String
    let onAssignChat: (UUID, UUID?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.text.identifier])
    }

    func dropEntered(info: DropInfo) {
        hoveredProjectDropID = projectID
        collapsedHistorySections.remove(collapseKey)
    }

    func dropExited(info: DropInfo) {
        if hoveredProjectDropID == projectID {
            hoveredProjectDropID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        hoveredProjectDropID = nil

        guard let provider = info.itemProviders(for: [UTType.text.identifier]).first else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let chatID = UUID(uuidString: string) else {
                return
            }

            DispatchQueue.main.async {
                onAssignChat(chatID, projectID)
            }
        }

        return true
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

@ViewBuilder
private func imageAttachmentThumbnail(_ attachment: ChatImageAttachment, size: CGSize) -> some View {
    if let image = attachment.previewImage {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
    } else {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .overlay {
                Image(systemName: "photo")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size.width, height: size.height)
    }
}

private struct AssistantTypingIndicator: View {
    private let dotCount = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 6) {
                ForEach(0..<dotCount, id: \.self) { index in
                    let intensity = dotIntensity(for: index, time: now)

                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.82 + (0.3 * intensity))
                        .opacity(0.3 + (0.7 * intensity))
                }
            }
            .frame(minWidth: 30, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant is thinking")
    }

    private func dotIntensity(for index: Int, time: TimeInterval) -> Double {
        let speed = 1.8
        let phase = time * speed - (Double(index) * 0.18)
        return (sin(phase * .pi * 2) + 1) / 2
    }
}

private struct AssistantMessageContent: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(contentBlocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let markdownText):
                    AssistantMarkdownText(text: markdownText)
                case .code(let language, let code):
                    AssistantCodeBlock(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentBlocks: [ContentBlock] {
        parseContentBlocks(from: text)
    }

    private func parseContentBlocks(from rawText: String) -> [ContentBlock] {
        let normalized = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [ContentBlock] = []
        var textBuffer: [String] = []
        var codeBuffer: [String] = []
        var codeLanguage: String?
        var isInsideCodeFence = false

        func flushTextBuffer() {
            let joined = textBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.markdown(joined))
            }
            textBuffer.removeAll(keepingCapacity: true)
        }

        func flushCodeBuffer() {
            let joined = codeBuffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            blocks.append(.code(language: codeLanguage, code: joined))
            codeBuffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.hasPrefix("```") {
                if isInsideCodeFence {
                    flushCodeBuffer()
                    isInsideCodeFence = false
                    codeLanguage = nil
                } else {
                    flushTextBuffer()
                    isInsideCodeFence = true

                    let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = language.isEmpty ? nil : language
                }

                continue
            }

            if isInsideCodeFence {
                codeBuffer.append(line)
            } else {
                textBuffer.append(line)
            }
        }

        if isInsideCodeFence {
            flushCodeBuffer()
        } else {
            flushTextBuffer()
        }

        return blocks.isEmpty ? [.markdown(normalized)] : blocks
    }

    private enum ContentBlock {
        case markdown(String)
        case code(language: String?, code: String)
    }
}

private struct AssistantMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let paragraph):
                    inlineMarkdownText(paragraph)
                case .heading(let level, let heading):
                    inlineMarkdownText(heading)
                        .font(headingFont(for: level))
                        .fontWeight(.semibold)
                case .unorderedList(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                inlineMarkdownText(item)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                case .orderedList(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(item.number).")
                                    .monospacedDigit()
                                inlineMarkdownText(item.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                case .separator:
                    EmptyView()
                }
            }
        }
        .lineSpacing(4)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [MarkdownBlock] {
        let lines = normalizedText.components(separatedBy: "\n")

        var parsedBlocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var unorderedItems: [String] = []
        var orderedItems: [OrderedListItem] = []

        func flushParagraph() {
            let paragraph = paragraphBuffer
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !paragraph.isEmpty {
                parsedBlocks.append(.paragraph(paragraph))
            }

            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        func flushUnorderedList() {
            guard !unorderedItems.isEmpty else { return }
            parsedBlocks.append(.unorderedList(unorderedItems))
            unorderedItems.removeAll(keepingCapacity: true)
        }

        func flushOrderedList() {
            guard !orderedItems.isEmpty else { return }
            parsedBlocks.append(.orderedList(orderedItems))
            orderedItems.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                continue
            }

            if trimmed.range(of: #"^---+$"#, options: .regularExpression) != nil {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                parsedBlocks.append(.separator)
                continue
            }

            if let heading = headingMatch(in: trimmed) {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                parsedBlocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let unorderedItem = unorderedListItem(in: trimmed) {
                flushParagraph()
                flushOrderedList()
                unorderedItems.append(unorderedItem)
                continue
            }

            if let orderedItem = orderedListItem(in: trimmed) {
                flushParagraph()
                flushUnorderedList()
                orderedItems.append(orderedItem)
                continue
            }

            flushUnorderedList()
            flushOrderedList()
            paragraphBuffer.append(trimmed)
        }

        flushParagraph()
        flushUnorderedList()
        flushOrderedList()

        return parsedBlocks
    }

    private var normalizedText: String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func inlineMarkdownText(_ text: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
        } else {
            Text(verbatim: text)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return .title2
        case 2:
            return .title3
        default:
            return .headline
        }
    }

    private func headingMatch(in line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }

        let hashes = line.prefix { $0 == "#" }
        let textStart = line.index(line.startIndex, offsetBy: hashes.count)
        let headingText = line[textStart...].trimmingCharacters(in: .whitespaces)

        guard !headingText.isEmpty else { return nil }
        return (level: hashes.count, text: headingText)
    }

    private func unorderedListItem(in line: String) -> String? {
        guard ["- ", "* ", "+ "].contains(where: { line.hasPrefix($0) }) else { return nil }
        return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private func orderedListItem(in line: String) -> OrderedListItem? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }

        let numberPart = line[..<dotIndex]
        guard let number = Int(numberPart) else { return nil }

        let textStart = line.index(after: dotIndex)
        let itemText = line[textStart...].trimmingCharacters(in: .whitespaces)
        guard !itemText.isEmpty else { return nil }

        return OrderedListItem(number: number, text: itemText)
    }

    private enum MarkdownBlock {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unorderedList([String])
        case orderedList([OrderedListItem])
        case separator
    }

    private struct OrderedListItem {
        let number: Int
        let text: String
    }
}

private struct AssistantCodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.lowercase)
                }

                Spacer(minLength: 0)

                Button {
                    UIPasteboard.general.string = code
                    copied = true

                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.tertiarySystemBackground))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(Color(.secondarySystemBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let onCopyUserMessage: () -> Void
    let onEditUserMessage: () -> Void
    let onRegenerateUserMessage: () -> Void
    let onSpeakAssistantMessage: () -> Void
    let isSpeakingAssistantMessage: Bool
    let onRegenerateAssistantMessage: () -> Void
    let accentColor: Color
    @State private var copied = false

    var body: some View {
        HStack {
            if message.role == .assistant {
                VStack(alignment: .leading, spacing: 6) {
                    assistantContent
                    assistantActions
                }
                Spacer(minLength: 50)
            } else {
                Spacer(minLength: 50)
                userBubble
            }
        }
    }

    private var assistantContent: some View {
        renderedAssistantText
            .textSelection(.enabled)
            .foregroundStyle(Color.primary)
    }

    private var userBubble: some View {
        userMessageContent
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(accentColor)
            )
            .foregroundStyle(Color.white)
            .contextMenu {
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

                Button {
                    onRegenerateUserMessage()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Image(systemName: "sparkles")
                        Text("Regenerate")
                    }
                }
            }
    }

    @ViewBuilder
    private var userMessageContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.imageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(message.imageAttachments) { attachment in
                            imageAttachmentThumbnail(attachment, size: CGSize(width: 140, height: 140))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }

            if !message.text.isEmpty || message.imageAttachments.isEmpty {
                Text(message.text.isEmpty ? "…" : message.text)
            }
        }
    }

    private var renderedAssistantText: some View {
        Group {
            if message.text.isEmpty {
                AssistantTypingIndicator()
            } else {
                AssistantMessageContent(text: message.text)
            }
        }
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

                Button {
                    onSpeakAssistantMessage()
                } label: {
                    Image(systemName: isSpeakingAssistantMessage ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSpeakingAssistantMessage ? .blue : .secondary)
                .accessibilityLabel(isSpeakingAssistantMessage ? "Stop reading aloud" : "Read aloud")
            }
        }
    }
}

private final class AssistantSpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speakingMessageID: UUID?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggleSpeech(for message: ChatMessage) {
        let text = speechText(from: message.text)
        guard !text.isEmpty else { return }

        if speakingMessageID == message.id && synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            speakingMessageID = nil
            return
        }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = true

        speakingMessageID = message.id
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakingMessageID = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakingMessageID = nil
        }
    }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        for language in Locale.preferredLanguages {
            if let voice = AVSpeechSynthesisVoice(language: language) {
                return voice
            }
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private func speechText(from rawText: String) -> String {
        rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"```"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[-*+]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\d+\.\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*(.*?)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\*(.*?)\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\n{2,}"#, with: ". ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension ChatImageAttachment {
    var previewImage: UIImage? {
        guard let separatorIndex = dataURL.firstIndex(of: ",") else { return nil }
        let encodedData = String(dataURL[dataURL.index(after: separatorIndex)...])
        guard let imageData = Data(base64Encoded: encodedData, options: .ignoreUnknownCharacters) else {
            return nil
        }

        return UIImage(data: imageData)
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
                            .font(.headline.weight(.semibold))

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
                            .font(.headline.weight(.semibold))

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
                                        .font(.subheadline)
                                        .frame(minHeight: 96)
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
                            .font(.headline.weight(.semibold))

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
                                    .font(.subheadline)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        Text("The backend requires an email and either a user ID or an API token.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
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
            .font(.subheadline)
            .keyboardType(keyboardType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsRow(
        icon: String,
        title: String,
        trailingText: String,
        trailingColor: Color? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular))
                .frame(width: 24)

            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            Spacer(minLength: 12)

            if let trailingColor {
                Circle()
                    .fill(trailingColor)
                    .frame(width: 16, height: 16)
            }

            Text(trailingText)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }
}
