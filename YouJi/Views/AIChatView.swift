import SwiftData
import SwiftUI
import UIKit

struct AIChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var conversation: AIConversation

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
    @FocusState private var composerFocused: Bool

    init(conversation: AIConversation) {
        self.conversation = conversation
        _messages = State(initialValue: conversation.messages)
    }

    var body: some View {
        VStack(spacing: 0) {
            conversationView
            composer
        }
        .background(chatBackground)
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                }
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            hasAIConfiguration = AISettingsStore.isConfigured
        }) {
            SettingsView(prioritizesAIConfiguration: true)
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
        .onDisappear {
            requestTask?.cancel()
            if messages.isEmpty {
                modelContext.delete(conversation)
                try? modelContext.save()
            } else {
                persistMessages()
            }
        }
        .overlay(alignment: .top) {
            if planSaved {
                Text("已保存到待玩与重温清单")
                    .font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(YJColor.ink, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var conversationView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    Text("这段对话使用创建时冻结的 \(conversation.games.count) 款游戏；同步后新建对话可使用最新记录。")
                        .font(.caption2).foregroundStyle(YJColor.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
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
            Image(systemName: "brain.head.profile")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 66, height: 66)
                .background(YJColor.purple, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
            Text("想聊点什么？")
                .font(.title2.bold())
            Text("问问你的游戏偏好、游玩方式，或者下一段冒险。")
                .font(.subheadline)
                .foregroundStyle(YJColor.muted)
                .multilineTextAlignment(.center)

            VStack(spacing: 9) {
                suggestionButton("我最偏爱哪类游戏？")
                suggestionButton("从投入时间看，我是什么类型的玩家？")
                suggestionButton("哪些游戏最值得我重新玩？")
            }
            .frame(maxWidth: 310)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }

    private func suggestionButton(_ text: String) -> some View {
        Button {
            draft = text
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
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(YJColor.purple, in: Circle())
            }

            Text(rendered(message.content))
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(message.role == .user ? Color.white : YJColor.ink)
                .lineSpacing(5)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    message.role == .user ? YJColor.ink : YJColor.card,
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
                .tint(YJColor.ink)
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
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(canSend ? YJColor.ink : YJColor.muted, in: Circle())
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
        guard !text.isEmpty, !isSending else { return }
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
        if conversation.titleGeneratedAt == nil,
           conversation.title == "新对话" {
            conversation.title = provisionalTitle(from: text)
        }
        persistMessages()
        draft = ""
        composerFocused = false
        isSending = true
        canRetry = false
        errorMessage = nil
        requestReply(requestMessages: requestMessages)
    }

    private func retryLastResponse() {
        guard !isSending, messages.last?.role == .user else { return }
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
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                messages.append(AIChatMessage(role: .assistant, content: answer))
                persistMessages()
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
        let title = planTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        modelContext.insert(SavedGamePlan(
            accountScopeKey: conversation.accountScopeKey,
            title: title,
            note: planNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        try? modelContext.save()
        showPlanEditor = false
        planTitleDraft = ""
        planNoteDraft = ""
        withAnimation { planSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation { planSaved = false } }
    }

    private func persistMessages() {
        conversation.messages = messages
        try? modelContext.save()
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
                conversation.title = title
                conversation.titleGeneratedAt = .now
                conversation.updatedAt = .now
                try? modelContext.save()
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
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
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
