import SwiftData
import SwiftUI
import UIKit

struct AIChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var conversation: AIConversation
    @Query private var generatedImages: [AIGeneratedImage]

    @State private var archiveRevision = LocalDataRevision.current
    @State private var messages: [AIChatMessage]
    @State private var persistedMessages: [AIChatMessage]
    @State private var input: AIChatDraft
    @State private var isSending = false
    @State private var isGeneratingTitle = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var hasAIConfiguration = false
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
    @FocusState private var composerFocused: Bool

    init(conversation: AIConversation, initialDraft: String = "") {
        self.conversation = conversation
        let storedMessages = conversation.messages
        _messages = State(initialValue: storedMessages)
        _persistedMessages = State(initialValue: storedMessages)
        let id = conversation.id
        let scope = conversation.accountScopeKey
        _generatedImages = Query(filter: #Predicate<AIGeneratedImage> {
            $0.ownerID == id && $0.originRaw == "conversation" && $0.accountScopeKey == scope
        })
        let storedDraft = !conversation.draft.isEmpty ? conversation.draft : storedMessages.isEmpty ? initialDraft : ""
        let initialText = conversation.draftRequestsImage && !storedDraft.isEmpty ? "画一张图：" + storedDraft : storedDraft
        _input = State(initialValue: AIChatDraft(text: initialText, requestsImage: false, storedText: conversation.draft))
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
            ToolbarItem(placement: .principal) {
                Text(conversation.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("数据使用", systemImage: "internaldrive") { showingConversationInfo = true }
                    Button("OpenAI 设置", systemImage: "gearshape") { showSettings = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("聊天选项")
            }
        }
        .sheet(isPresented: $showingConversationInfo) {
            AIChatDataUseView()
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            hasAIConfiguration = AISettingsStore.isConfigured
        }) {
            SettingsView(prioritizesAIConfiguration: true)
        }
        .sheet(isPresented: $showPlans) {
            SavedPlansView(accountScopeKey: conversation.accountScopeKey)
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
        .onAppear {
            hasAIConfiguration = AISettingsStore.isConfigured
            activateDraft()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { input.flush() }
        }
        .onDisappear {
            input.deactivate()
            requestTask?.cancel()
            titleTask?.cancel()
            activeRequestID = nil
            isSending = false
            canRetry = messages.last?.role == .user
            guard archiveRevision == LocalDataRevision.current,
                  conversation.modelContext != nil, !conversation.isDeleted,
                  !conversation.hasUnreadableContent else { return }
            do {
                if messages.isEmpty && input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try LocalPersistence.transaction(modelContext) { writer in
                        let stored = try LocalPersistence.conversation(conversation.id, in: writer)
                        if stored.canDiscardEmptyConversation { writer.delete(stored) }
                    }
                }
            } catch { errorMessage = "草稿未能保存：\(error.localizedDescription)" }
        }
    }

    private var conversationView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 22) {
                    if messages.isEmpty && !isSending {
                        emptyConversation
                    }

                    ForEach(messages) { message in
                        AIChatMessageBubble(message: message,
                            image: message.imageID.flatMap { id in generatedImages.first { $0.id == id } },
                            preparePlan: preparePlan)
                            .equatable().id(message.id)
                    }

                    if isSending {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("正在回复…")
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
            .defaultScrollAnchor(messages.isEmpty ? .top : .bottom)
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
        VStack(alignment: .leading, spacing: 18) {
            Text("聊聊你的游戏").font(.title3.weight(.semibold))
            Text("总结最近的游玩，也可以直接让我画一张游戏画像。")
                .font(.subheadline).foregroundStyle(YJColor.muted)
            VStack(spacing: 10) {
                suggestionButton("总结最近 30 天", draft: AIPrompts.recentMonthDraft)
                suggestionButton("今晚玩什么？", draft: AIPrompts.shortSessionDraft)
                suggestionButton("画一张游戏画像", draft: AIPrompts.gamePortraitDraft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 36)
    }

    private func suggestionButton(_ text: String, draft suggestedDraft: String? = nil) -> some View {
        Button {
            input.text = suggestedDraft ?? text
            composerFocused = true
        } label: {
            HStack {
                Text(text)
                Spacer()
                Image(systemName: "arrow.up.left")
            }
            .font(.subheadline)
            .foregroundStyle(YJColor.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(YJColor.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(YJColor.line))
        }
        .buttonStyle(.plain)
    }

    private var composer: some View {
        AIChatComposer(input: input, hasConfiguration: hasAIConfiguration,
            isSending: isSending,
            canRetry: canRetry, hasPendingMessage: messages.last?.role == .user,
            focus: $composerFocused,
            configure: { showSettings = true }, send: sendMessage,
            retry: retryLastResponse, stop: stopResponse)
    }

    private func stopResponse() {
        requestTask?.cancel()
        activeRequestID = nil
        isSending = false
        canRetry = true
    }

    private func sendMessage() {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, !conversation.hasUnreadableContent,
              archiveRevision == LocalDataRevision.current else { return }
        guard hasAIConfiguration else {
            showSettings = true
            return
        }
        let userMessage = AIChatMessage(role: .user, content: text)
        let requestMessages = messages + [userMessage]
        input.cancelPendingSave()
        messages.append(userMessage)
        do {
            try persistMessages(draftValue: "", provisionalTitle: provisionalTitle(from: text))
        } catch {
            messages.removeLast()
            input.scheduleSave()
            errorMessage = "消息未能保存：\(error.localizedDescription)"
            return
        }
        input.text = ""
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
        let imageModel = AISettingsStore.imageModelName
        let queries = AIChatGameQueries(accountScope: conversation.accountScopeKey, in: modelContext, revision: archiveRevision)
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
                let result = try await AIAnalysisClient.shared.chat(messages: requestMessages,
                    apiKey: apiKey, model: model, imageModel: imageModel, queries: queries)
                guard activeRequestID == requestID else { return }
                let reply = try AIImageService.saveChatReply(result, model: imageModel, conversationID: conversation.id,
                    accountScope: conversation.accountScopeKey, expectedMessages: requestMessages,
                    revision: archiveRevision, in: modelContext)
                messages.append(reply)
                persistedMessages = messages
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

    private func activateDraft() {
        input.activate { value in
            try LocalDataRevision.check(archiveRevision)
            guard conversation.modelContext != nil, !conversation.isDeleted,
                  !conversation.hasUnreadableContent else { throw CancellationError() }
            try LocalPersistence.transaction(modelContext) { writer in
                let stored = try LocalPersistence.conversation(conversation.id, in: writer)
                guard !stored.hasUnreadableContent else { throw CancellationError() }
                stored.updateDraft(value.text, requestsImage: value.requestsImage)
            }
        } onError: { error in
            guard !(error is CancellationError) else { return }
            errorMessage = "草稿未能保存：\(error.localizedDescription)"
        }
    }

    private func persistMessages(draftValue: String? = nil, provisionalTitle: String? = nil) throws {
        try LocalDataRevision.check(archiveRevision)
        guard conversation.modelContext != nil, !conversation.isDeleted, !conversation.hasUnreadableContent else {
            throw CancellationError()
        }
        let savedDraft = AIChatDraft.Value(text: draftValue ?? input.text, requestsImage: input.requestsImage)
        try AIConversationActions.persistMessages(conversation.id, messages: messages, expecting: persistedMessages,
            draft: savedDraft.text, requestsImage: false, provisionalTitle: provisionalTitle,
            revision: archiveRevision, in: modelContext)
        persistedMessages = messages
        input.acknowledgeSaved(savedDraft)
    }

    private func generateTitleIfNeeded(apiKey: String, model: String) {
        let assistantReplies = messages.filter { $0.role == .assistant }.count
        guard assistantReplies >= 2,
              conversation.titleGeneratedAt == nil,
              !isGeneratingTitle else { return }

        isGeneratingTitle = true
        let titleMessages = messages
        let originalTitle = conversation.title
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
                    guard stored.titleGeneratedAt == nil, stored.title == originalTitle else { return }
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

    private var chatBackground: some View { YJColor.paper.ignoresSafeArea() }

}


private struct AIChatMessageBubble: View, Equatable {
    let message: AIChatMessage
    let image: AIGeneratedImage?
    let imageAvailable: Bool
    let preparePlan: (AIChatMessage) -> Void
    @ScaledMetric(relativeTo: .body) private var fontSize = 15.0

    init(message: AIChatMessage, image: AIGeneratedImage?, preparePlan: @escaping (AIChatMessage) -> Void) {
        self.message = message
        self.image = image
        self.imageAvailable = image != nil
        self.preparePlan = preparePlan
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.imageAvailable == rhs.imageAvailable
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 10) {
                if message.imageID != nil {
                    if let image { AIGeneratedImageTile(image: image) }
                    else { Label("图片暂时不可用", systemImage: "photo").font(.caption).foregroundStyle(YJColor.muted) }
                }
                if !message.content.isEmpty {
                    Text(YJText.markdown(message.content))
                        .font(.system(size: fontSize)).foregroundStyle(YJColor.ink)
                        .lineSpacing(3).textSelection(.enabled)
                        .padding(.horizontal, message.role == .user ? 13 : 0)
                        .padding(.vertical, message.role == .user ? 10 : 0)
                        .background(message.role == .user ? YJColor.card : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 20))
                }
                if message.role == .assistant {
                    if message.usedLocalRecords {
                        Label("已查询本机记录", systemImage: "internaldrive")
                            .font(.caption2).foregroundStyle(YJColor.muted)
                    }
                    HStack(spacing: 18) {
                        if !message.content.isEmpty {
                            Button { UIPasteboard.general.string = message.content } label: { Image(systemName: "doc.on.doc") }
                                .accessibilityLabel("复制回复")
                        }
                        if message.imageID == nil {
                            Button { preparePlan(message) } label: { Image(systemName: "bookmark") }
                                .accessibilityLabel("保存为待玩灵感")
                        } else {
                            Text("点开图片保存或分享").font(.caption2)
                        }
                    }.font(.caption).foregroundStyle(YJColor.muted).buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            .contextMenu {
                if !message.content.isEmpty {
                    Button { UIPasteboard.general.string = message.content } label: { Label("复制", systemImage: "doc.on.doc") }
                }
                if message.role == .assistant && message.imageID == nil {
                    Button { preparePlan(message) } label: { Label("加入待玩", systemImage: "bookmark") }
                }
            }
        }.frame(maxWidth: .infinity)
    }
}

private struct AIChatComposer: View {
    @Bindable var input: AIChatDraft
    let hasConfiguration: Bool
    let isSending: Bool
    let canRetry: Bool
    let hasPendingMessage: Bool
    let focus: FocusState<Bool>.Binding
    let configure: () -> Void
    let send: () -> Void
    let retry: () -> Void
    let stop: () -> Void
    @ScaledMetric(relativeTo: .body) private var fontSize = 15.0

    private var canSend: Bool {
        !isSending && !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            if canRetry && !isSending && hasPendingMessage {
                Button("重新生成上一条回复", action: retry).font(.caption).foregroundStyle(YJColor.muted)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("总结最近 30 天", systemImage: "calendar") { fill(AIPrompts.recentMonthDraft) }
                    Button("画一张游戏画像", systemImage: "photo") { fill(AIPrompts.gamePortraitDraft) }
                    Button("OpenAI 设置", systemImage: "gearshape", action: configure)
                } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                        .frame(width: 36, height: 44).contentShape(Rectangle())
                }.foregroundStyle(YJColor.muted).accessibilityLabel("聊天快捷操作")
                TextField("发消息，也可以让我画图", text: $input.text, axis: .vertical)
                    .font(.system(size: fontSize)).lineLimit(1...5).focused(focus)
                    .submitLabel(.send).onSubmit(send).padding(.vertical, 8)
                Button(action: isSending ? stop : send) {
                    Image(systemName: isSending ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSending || canSend ? YJColor.paper : YJColor.muted)
                        .frame(width: 34, height: 34)
                        .background(isSending || canSend ? YJColor.lime : YJColor.elevated, in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!isSending && !canSend)
                    .accessibilityLabel(isSending ? "停止生成" : "发送")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(YJColor.card, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(YJColor.line, lineWidth: 0.5))
            if !hasConfiguration {
                Button("配置 OpenAI 后即可发送", action: configure)
                    .font(.caption2).foregroundStyle(YJColor.muted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(YJColor.paper)
        .onChange(of: input.text) { _, _ in input.scheduleSave() }
    }

    private func fill(_ text: String) {
        input.text = text
        focus.wrappedValue = true
    }
}

private struct AIChatDataUseView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("发送给 OpenAI") {
                    Text("发送消息时会提供当前对话。需要游戏数据时，AI 会按问题查询这段对话对应的本机档案，只接收匹配结果。")
                }
                Section("游玩时长") {
                    Text("游玩日按本地时间从早上 6 点开始，到次日早上 6 点前结束。")
                }
            }
            .scrollContentBackground(.hidden).background(YJColor.paper)
            .navigationTitle("数据使用").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}
