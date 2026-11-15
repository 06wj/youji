import SwiftData
import SwiftUI

struct AIChatListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIConversation.updatedAt, order: .reverse) private var conversations: [AIConversation]

    let accountScopeKey: String
    let initialDraft: String?

    init(accountScopeKey: String, initialDraft: String? = nil) {
        self.accountScopeKey = accountScopeKey
        self.initialDraft = initialDraft
    }

    @State private var path: [UUID] = []
    @State private var didOpenInitialDraft = false
    @State private var conversationToDelete: AIConversation?
    @State private var persistenceError: String?

    private var scopedConversations: [AIConversation] {
        conversations.filter { $0.usesLocalQueries == true && $0.accountScopeKey == accountScopeKey }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if scopedConversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .background(chatListBackground)
            .navigationTitle("游戏聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { createConversation() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新建对话")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let conversation = scopedConversations.first(where: { $0.id == id }) {
                    AIChatView(conversation: conversation)
                } else {
                    ContentUnavailableView("对话不存在", systemImage: "message.slash")
                }
            }
            .task {
                if !didOpenInitialDraft, let initialDraft {
                    didOpenInitialDraft = true
                    createConversation(draft: initialDraft)
                }
            }
            .alert("本地保存失败", isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(persistenceError ?? "未知错误")
            }
            .confirmationDialog(
                "删除这段对话？",
                isPresented: Binding(
                    get: { conversationToDelete != nil },
                    set: { if !$0 { conversationToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive, action: deleteConversation)
                Button("取消", role: .cancel) { conversationToDelete = nil }
            } message: {
                Text("删除后无法恢复。")
            }
        }
    }

    private var conversationList: some View {
        List {
            YJFeatureHeading(eyebrow: "CONTINUE YOUR STORY", title: "好游戏，值得聊。",
                             subtitle: "重温灵感，继续下一段对话。", artwork: "MemoryCrystal")
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 18, trailing: 0))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            ForEach(scopedConversations) { conversation in
                NavigationLink(value: conversation.id) {
                    conversationRow(conversation)
                }
                .listRowBackground(YJColor.card)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("删除", role: .destructive) {
                        conversationToDelete = conversation
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func conversationRow(_ conversation: AIConversation) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "message.fill")
                .font(.subheadline.bold())
                .foregroundStyle(YJColor.purple)
                .frame(width: 40, height: 40)
                .background(YJColor.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(conversation.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(YJColor.muted)
                }
                Text(conversation.preview)
                    .font(.caption)
                    .foregroundStyle(YJColor.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                YJFeatureHeading(eyebrow: "PLAYER TWO, READY", title: "你的下一场冒险，\n一起想。",
                                 subtitle: "聊偏好，聊回忆，也聊下一个想去的世界。", artwork: "MemoryCrystal")
                VStack(alignment: .leading, spacing: 12) {
                    Text("从一句好奇开始").font(.title3.bold())
                    Text("游戏大脑可按问题查找本机的游玩记录。")
                        .font(.subheadline).foregroundStyle(YJColor.muted).lineSpacing(5)
                    Button("开始聊天") { createConversation() }
                        .buttonStyle(YJPrimaryButtonStyle())
                }.padding(20).youjiCard()
            }.padding(18)
        }
    }

    private func createConversation(draft: String = "") {
        do {
            let conversation = try AIConversationActions.create(
                accountScope: accountScopeKey, draft: draft, in: modelContext
            )
            path.append(conversation.id)
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func deleteConversation() {
        guard let conversationToDelete else { return }
        LocalDataRevision.invalidate()
        do { try LocalPersistence.transaction(modelContext) { writer in
            try AIImageService.deleteImages(ownerID: conversationToDelete.id, origin: .conversation, in: writer)
            writer.delete(try LocalPersistence.conversation(conversationToDelete.id, in: writer))
        } }
        catch {
            persistenceError = error.localizedDescription
        }
        self.conversationToDelete = nil
    }

    private var chatListBackground: some View {
        ZStack {
            YJColor.paper
            Circle()
                .fill(YJColor.purple.opacity(0.08))
                .frame(width: 300, height: 300)
                .blur(radius: 18)
                .offset(x: 170, y: -300)
        }
        .ignoresSafeArea()
    }
}


@MainActor
enum AIConversationActions {
    static func persistMessages(_ id: UUID, messages: [AIChatMessage], expecting: [AIChatMessage],
                                draft: String, requestsImage: Bool, provisionalTitle: String? = nil,
                                revision: UUID, in context: ModelContext) throws {
        try LocalDataRevision.check(revision)
        try LocalPersistence.transaction(context) { writer in
            let stored = try LocalPersistence.conversation(id, in: writer)
            guard stored.usesLocalQueries == true,
                  try stored.readMessages() == expecting else { throw AIConversationWriteError.changed }
            if stored.messages != messages { stored.messages = messages }
            stored.updateDraft(draft, requestsImage: requestsImage)
            if let provisionalTitle, stored.titleGeneratedAt == nil, stored.title == "新对话" {
                stored.title = provisionalTitle
                stored.updatedAt = .now
            }
        }
    }

    /// Never expose the disposable writer's model to a SwiftUI destination.
    static func create(accountScope: String, draft: String, requestsImage: Bool = false,
                       in context: ModelContext) throws -> AIConversation {
        let id = UUID()
        try LocalPersistence.transaction(context) { writer in
            let conversation = AIConversation(id: id, accountScopeKey: accountScope, draft: draft)
            conversation.draftRequestsImage = requestsImage
            writer.insert(conversation)
        }
        return try LocalPersistence.conversation(id, in: context)
    }

    static func removeSnapshotConversations(in context: ModelContext) throws {
        let obsolete = FetchDescriptor<AIConversation>(predicate: #Predicate {
            $0.usesLocalQueries == nil || $0.usesLocalQueries == false
        })
        guard try context.fetchCount(obsolete) > 0 else { return }
        try LocalPersistence.transaction(context) { writer in
            let legacy = try writer.fetch(obsolete)
            let legacyIDs = Set(legacy.map(\.id))
            let kind = AIGeneratedImage.Origin.conversation.rawValue
            let images = try writer.fetch(FetchDescriptor<AIGeneratedImage>(predicate: #Predicate { $0.originRaw == kind }))
            for image in images where legacyIDs.contains(image.ownerID) {
                writer.delete(image)
            }
            for conversation in legacy { writer.delete(conversation) }
        }
    }
}
