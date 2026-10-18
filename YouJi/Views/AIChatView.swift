import SwiftData
import SwiftUI
import UIKit

struct AIChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var conversation: AIConversation
    @Query private var allGames: [GameRecord]

    @State private var archiveRevision = LocalDataRevision.current
    @State private var messages: [AIChatMessage]
    @State private var draft = ""
    @State private var isSending = false
    @State private var isGeneratingTitle = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var hasAIConfiguration = AISettingsStore.isConfigured
    @State private var requestTask: Task<Void, Never>?
    @State private var titleTask: Task<Void, Never>?
    @State private var activeRequestID: UUID?
    @State private var canRetry = false
    @State private var planSaved = false
    @State private var showPlanEditor = false
    @State private var planTitleDraft = ""
    @State private var planNoteDraft = ""
    @State private var showingConversationInfo = false
    @State private var showPlans = false
    @State private var newConversation: AIConversation?
    @FocusState private var composerFocused: Bool

    init(conversation: AIConversation, initialDraft: String = "") {
        self.conversation = conversation
        _messages = State(initialValue: conversation.messages)
        _draft = State(initialValue: !conversation.draft.isEmpty ? conversation.draft
                       : conversation.messages.isEmpty ? initialDraft : "")
        _canRetry = State(initialValue: conversation.needsReply)
    }

    var body: some View {
        VStack(spacing: 0) {
            if archiveRevision != LocalDataRevision.current {
                Text("档案已更新，请返回列表重新打开对话。")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
            if conversation.hasUnreadableContent {
                ContentUnavailableView("这段对话暂时无法读取", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text("原始内容已保留。你可以在设置中导出完整备份，或恢复此前的备份。"))
            } else {
                contextVersion
                conversationView
            }
            if planSaved {
                HStack {
                    Label("已加入待玩", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Button("查看清单") { showPlans = true }
                    Button { planSaved = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("收起提示")
                }
                .font(.caption.bold()).foregroundStyle(YJColor.lime)
                .padding(12).background(YJColor.card)
            }
            composer.disabled(conversation.hasUnreadableContent || archiveRevision != LocalDataRevision.current)
        }
        .background(chatBackground)
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingConversationInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("对话说明")
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                }
            }
        }
        .alert("对话说明", isPresented: $showingConversationInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("这段对话会沿用开始聊天时的 \(conversation.games.count) 款游戏记录。同步后如需使用最新记录，请新建对话。")
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            hasAIConfiguration = AISettingsStore.isConfigured
        }) {
            SettingsView(prioritizesAIConfiguration: true)
        }
        .sheet(isPresented: $showPlans) {
            SavedPlansView(accountScopeKey: conversation.accountScopeKey)
        }
        .sheet(item: $newConversation) { next in
            NavigationStack {
                AIChatView(conversation: next)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("完成") { newConversation = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $showPlanEditor) {
            NavigationStack {
                Form {
                    Section("计划名称") {
                        TextField("准备玩或重温什么", text: $planTitleDraft)
                    }
                    Section("保留的 AI 建议") {
                        TextEditor(text: $planNoteDraft)
                            .frame(minHeight: 180)
                    }
                }
                .navigationTitle("保存为行动计划")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { showPlanEditor = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存", action: savePlanDraft)
                            .fontWeight(.semibold)
                            .disabled(planTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("聊天失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            if canRetry { Button("重试") { retryLastResponse() } }
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .task {
            // A caller may supply a seed draft, but opening a conversation never
            // submits it. Persist the seed so returning later keeps the task.
            saveDraft()
        }
        .onChange(of: draft) { _, _ in saveDraft() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveDraft() }
        }
        .onDisappear {
            requestTask?.cancel()
            titleTask?.cancel()
            activeRequestID = nil
            isSending = false
            canRetry = messages.last?.role == .user
            guard archiveRevision == LocalDataRevision.current,
                  conversation.modelContext != nil, !conversation.isDeleted,
                  !conversation.hasUnreadableContent else { return }
            do {
                try persistMessages()
                if messages.isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try LocalPersistence.transaction(modelContext) { writer in
                        let stored = try LocalPersistence.conversation(conversation.id, in: writer)
                        if stored.canDiscardEmptyConversation { writer.delete(stored) }
                    }
                }
            } catch { errorMessage = "草稿未能保存：\(error.localizedDescription)" }
        }
    }

    private var latestGames: [AIAnalysisGame] {
        AIGameContext.snapshot(AIGameContext.games(in: conversation.accountScopeKey, from: allGames))
    }

    private var contextHasChanged: Bool {
        AIGameContext.hasChanged(frozen: conversation.games, latest: latestGames)
    }

    private var contextVersion: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("游戏记录 · \(conversation.createdAt.formatted(.dateTime.year().month().day())) · \(conversation.games.count) 款", systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(YJColor.muted)
            if contextHasChanged {
                if latestGames.isEmpty {
                    Text("本地已没有符合条件的游戏，仍可围绕这份旧记录聊天。")
                        .font(.caption2).foregroundStyle(YJColor.muted)
                } else {
                    Button(action: startWithLatestRecords) {
                        Label("记录有变化 · 用最新记录新开对话", systemImage: "square.and.pencil")
                            .font(.caption.bold())
                    }
                    .disabled(isSending || archiveRevision != LocalDataRevision.current)
                    Text("原对话保留；最近的问题会成为新草稿，点发送后开始。")
                        .font(.caption2).foregroundStyle(YJColor.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(YJColor.card.opacity(0.6))
    }

    private func startWithLatestRecords() {
        guard !latestGames.isEmpty, !isSending, archiveRevision == LocalDataRevision.current else { return }
        let seed = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AIPrompts.latestRecordDraft(messages: messages) : draft
        do {
            newConversation = try AIConversationActions.create(
                accountScope: conversation.accountScopeKey, games: latestGames, draft: seed, in: modelContext
            )
        } catch {
            errorMessage = "新对话未能保存：\(error.localizedDescription)"
        }
    }

    private var conversationView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if messages.isEmpty && !isSending {
                        emptyConversation
                    }

                    ForEach(messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if isSending {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("AI 正在回复…")
                                .font(.caption)
                                .foregroundStyle(YJColor.muted)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .id("chat-loading")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isSending) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyConversation: some View {
        VStack(spacing: 16) {
            YJFeatureHeading(eyebrow: "LET’S TALK GAMES", title: "想聊点什么？",
                             subtitle: "你的偏好、你的玩法、你的下一场冒险。", artwork: "MemoryCrystal")

            VStack(spacing: 9) {
                suggestionButton("今晚只有 30 分钟", draft: AIPrompts.shortSessionDraft)
                suggestionButton("从已有游戏选一款重温", draft: AIPrompts.replayDraft)
                suggestionButton("我最偏爱哪类游戏？")
            }
            .frame(maxWidth: 310)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func suggestionButton(_ text: String, draft suggestedDraft: String? = nil) -> some View {
        Button {
            draft = suggestedDraft ?? text
            composerFocused = true
        } label: {
            HStack {
                Text(text)
                Spacer()
                Image(systemName: "arrow.up.left")
            }
            .font(.subheadline.bold())
            .foregroundStyle(YJColor.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(YJColor.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(YJColor.line))
        }
        .buttonStyle(.plain)
    }

    private func messageBubble(_ message: AIChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 9) {
            if message.role == .user { Spacer(minLength: 46) }

            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(YJColor.purple)
                    .frame(width: 28, height: 28)
                    .background(YJColor.purple.opacity(0.14), in: Circle())
            }

            VStack(alignment: .leading, spacing: 7) {
            Text(rendered(message.content))
                .font(.body)
                .foregroundStyle(message.role == .user ? YJColor.paper : YJColor.ink)
                .lineSpacing(5)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    message.role == .user ? YJColor.lime : YJColor.card,
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .overlay {
                    if message.role == .assistant {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke(YJColor.line)
                    }
                }
                .contextMenu {
                    Button { UIPasteboard.general.string = message.content } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    if message.role == .assistant {
                        Button { preparePlan(message) } label: {
                            Label("保存为待玩灵感", systemImage: "bookmark")
                        }
                    }
                }
                if message.role == .assistant {
                    HStack(spacing: 14) {
                        Button { preparePlan(message) } label: {
                            Label("加入待玩", systemImage: "bookmark")
                        }
                        Button { UIPasteboard.general.string = message.content } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                    }
                    .font(.caption.bold()).foregroundStyle(YJColor.lime)
                    .buttonStyle(.plain).padding(.horizontal, 4)
                }
            }

            if message.role == .assistant { Spacer(minLength: 38) }
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if !hasAIConfiguration {
                Button {
                    showSettings = true
                } label: {
                    Label("先配置 AI 服务后开始聊天", systemImage: "key.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .tint(YJColor.lime)
            }
            if canRetry && !isSending && messages.last?.role == .user {
                Button("继续生成上一条回复") { retryLastResponse() }
                    .font(.caption.bold())
            }
            if isSending {
                Button("停止生成") {
                    requestTask?.cancel()
                    activeRequestID = nil
                    isSending = false
                    canRetry = true
                }
                .font(.caption.bold()).foregroundStyle(YJColor.coral)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("问问你的游戏记录…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(sendMessage)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(YJColor.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(YJColor.line))

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up")
                        .font(.headline.bold())
                        .foregroundStyle(canSend ? YJColor.paper : YJColor.muted)
                        .frame(width: 44, height: 44)
                        .background(canSend ? YJColor.lime : YJColor.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var canSend: Bool {
        hasAIConfiguration
            && !conversation.games.isEmpty
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !conversation.hasUnreadableContent,
              archiveRevision == LocalDataRevision.current else { return }
        guard hasAIConfiguration else {
            showSettings = true
            return
        }
        guard !conversation.games.isEmpty else {
            errorMessage = "这段对话缺少游戏信息，请新建对话。"
            return
        }

        let userMessage = AIChatMessage(role: .user, content: text)
        let requestMessages = messages + [userMessage]
        messages.append(userMessage)
        do {
            try persistMessages(draftValue: "", provisionalTitle: provisionalTitle(from: text))
        } catch {
            messages.removeLast()
            errorMessage = "消息未能保存：\(error.localizedDescription)"
            return
        }
        draft = ""
        composerFocused = false
        isSending = true
        canRetry = false
        errorMessage = nil
        requestReply(requestMessages: requestMessages)
    }

    private func retryLastResponse() {
        guard hasAIConfiguration else { showSettings = true; return }
        guard !isSending, messages.last?.role == .user, !conversation.hasUnreadableContent,
              archiveRevision == LocalDataRevision.current else { return }
        errorMessage = nil
        isSending = true
        canRetry = false
        requestReply(requestMessages: messages)
    }

    private func requestReply(requestMessages: [AIChatMessage]) {
        let apiKey = AISettingsStore.apiKey
        let model = AISettingsStore.modelName
        let requestID = UUID()
        activeRequestID = requestID
        requestTask = Task {
            defer {
                if activeRequestID == requestID {
                    isSending = false
                    activeRequestID = nil
                    requestTask = nil
                }
            }
            do {
                let answer = try await AIAnalysisClient.shared.chat(
                    games: conversation.games,
                    messages: requestMessages,
                    apiKey: apiKey,
                    model: model
                )
                try LocalDataRevision.check(archiveRevision)
                guard conversation.modelContext != nil, !conversation.isDeleted else { return }
                guard activeRequestID == requestID else { return }
                messages.append(AIChatMessage(role: .assistant, content: answer))
                do {
                    try persistMessages()
                } catch {
                    messages.removeLast()
                    throw error
                }
                generateTitleIfNeeded(apiKey: apiKey, model: model)
            } catch is CancellationError {
                // Leaving the view cancels the reply without losing the user's message.
            } catch {
                guard activeRequestID == requestID else { return }
                canRetry = true
                errorMessage = error.localizedDescription
            }
        }
    }

    private func preparePlan(_ message: AIChatMessage) {
        let firstLine = message.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? conversation.title
        planTitleDraft = String(firstLine.prefix(28))
        planNoteDraft = message.content
        showPlanEditor = true
    }

    private func savePlanDraft() {
        guard archiveRevision == LocalDataRevision.current,
              conversation.modelContext != nil, !conversation.isDeleted else {
            errorMessage = "档案已更新，请重新打开对话后再保存。"
            return
        }
        let title = planTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let plan = SavedGamePlan(
            accountScopeKey: conversation.accountScopeKey,
            title: title,
            note: planNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceConversationID: conversation.id.uuidString
        )
        do {
            try LocalPersistence.transaction(modelContext) { $0.insert(plan) }
        } catch {
            errorMessage = "计划未能保存：\(error.localizedDescription)"
            return
        }
        showPlanEditor = false
        planTitleDraft = ""
        planNoteDraft = ""
        withAnimation { planSaved = true }
    }

    private func saveDraft() {
        guard archiveRevision == LocalDataRevision.current,
              conversation.modelContext != nil, !conversation.isDeleted,
              !conversation.hasUnreadableContent else { return }
        do {
            try LocalDataRevision.check(archiveRevision)
            try LocalPersistence.transaction(modelContext) { writer in
                let stored = try LocalPersistence.conversation(conversation.id, in: writer)
                stored.updateDraft(draft)
            }
        } catch { errorMessage = "草稿未能保存：\(error.localizedDescription)" }
    }

    private func persistMessages(draftValue: String? = nil, provisionalTitle: String? = nil) throws {
        try LocalDataRevision.check(archiveRevision)
        guard conversation.modelContext != nil, !conversation.isDeleted, !conversation.hasUnreadableContent else {
            throw CancellationError()
        }
        try LocalPersistence.transaction(modelContext) { writer in
            let stored = try LocalPersistence.conversation(conversation.id, in: writer)
            if stored.messages != messages { stored.messages = messages }
            stored.updateDraft(draftValue ?? draft)
            if let provisionalTitle, stored.titleGeneratedAt == nil, stored.title == "新对话" {
                stored.title = provisionalTitle
                stored.updatedAt = .now
            }
        }
    }

    private func generateTitleIfNeeded(apiKey: String, model: String) {
        let assistantReplies = messages.filter { $0.role == .assistant }.count
        guard assistantReplies >= 2,
              conversation.titleGeneratedAt == nil,
              !isGeneratingTitle else { return }

        isGeneratingTitle = true
        let titleMessages = messages
        titleTask = Task {
            defer {
                isGeneratingTitle = false
                titleTask = nil
            }
            do {
                let title = try await AIAnalysisClient.shared.conversationTitle(
                    messages: titleMessages,
                    apiKey: apiKey,
                    model: model
                )
                try LocalDataRevision.check(archiveRevision)
                guard conversation.modelContext != nil, !conversation.isDeleted, !conversation.hasUnreadableContent else { return }
                try LocalPersistence.transaction(modelContext) { writer in
                    let stored = try LocalPersistence.conversation(conversation.id, in: writer)
                    stored.title = title
                    stored.titleGeneratedAt = .now
                    stored.updatedAt = .now
                }
            } catch {
                // A generated title is optional; retry after a later reply.
            }
        }
    }

    private func provisionalTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let compact = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > 14 else { return compact }
        return "\(compact.prefix(14))…"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                if isSending {
                    proxy.scrollTo("chat-loading", anchor: .bottom)
                } else if let lastID = messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private func rendered(_ text: String) -> AttributedString {
        YJText.markdown(text)
    }

    private var chatBackground: some View {
        ZStack {
            YJColor.paper
            Circle()
                .fill(YJColor.purple.opacity(0.08))
                .frame(width: 300, height: 300)
                .blur(radius: 18)
                .offset(x: 170, y: -300)
            Circle()
                .fill(YJColor.lime.opacity(0.08))
                .frame(width: 280, height: 280)
                .blur(radius: 16)
                .offset(x: -170, y: 360)
        }
        .ignoresSafeArea()
    }
}
