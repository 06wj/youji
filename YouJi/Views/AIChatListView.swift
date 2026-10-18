import SwiftData
import SwiftUI

struct AIChatListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIConversation.updatedAt, order: .reverse) private var conversations: [AIConversation]
    @Query private var allGames: [GameRecord]

    let games: [GameRecord]
    let accountScopeKey: String
    let initialDraft: String?

    init(games: [GameRecord], accountScopeKey: String, initialDraft: String? = nil) {
        self.games = games
        self.accountScopeKey = accountScopeKey
        self.initialDraft = initialDraft
    }

    @State private var path: [UUID] = []
    @State private var didOpenInitialDraft = false
    @State private var conversationToDelete: AIConversation?
    @State private var persistenceError: String?

    private var scopedConversations: [AIConversation] {
        conversations.filter { $0.accountScopeKey == accountScopeKey }
    }

    private var chatGames: [AIAnalysisGame] { AIGameContext.snapshot(games) }

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
                    .disabled(chatGames.isEmpty)
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
                if !didOpenInitialDraft, let initialDraft, !chatGames.isEmpty {
                    didOpenInitialDraft = true
                    createConversation(draft: initialDraft)
                }
                if conversations.contains(where: { $0.accountScopeKey.isEmpty }) {
                    do {
                        try AIConversationActions.migrateLegacyConversations(
                            to: accountScopeKey, games: allGames, in: modelContext
                        )
                    } catch {
                        persistenceError = error.localizedDescription
                    }
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
                    Text(chatGames.isEmpty ? "至少需要一款游玩超过 1 小时的游戏才能开始聊天。" : "游戏大脑会带上你的游玩记录，记住每一段对话。")
                        .font(.subheadline).foregroundStyle(YJColor.muted).lineSpacing(5)
                    Button("开始聊天") { createConversation() }
                        .buttonStyle(YJPrimaryButtonStyle()).disabled(chatGames.isEmpty)
                }.padding(20).youjiCard()
            }.padding(18)
        }
    }

    private func createConversation(draft: String = "") {
        guard !chatGames.isEmpty else { return }
        do {
            let conversation = try AIConversationActions.create(
                accountScope: accountScopeKey, games: chatGames, draft: draft, in: modelContext
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
            writer.delete(try LocalPersistence.conversation(conversationToDelete.id, in: writer))
        } }
        catch {
            persistenceError = error.localizedDescription
        }
        self.conversationToDelete = nil
    }

    private func trophyText(_ game: GameRecord) -> String {
        let percent = Int((Double(game.trophiesEarned) / Double(game.trophiesDefined) * 100).rounded())
        let platinum = game.platinumTrophiesEarned > 0 ? " · 已白金" : ""
        return "\(game.trophiesEarned)/\(game.trophiesDefined)（\(percent)%）\(platinum)"
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
    /// Never expose the disposable writer's model to a SwiftUI destination.
    static func create(accountScope: String, games: [AIAnalysisGame], draft: String,
                       in context: ModelContext) throws -> AIConversation {
        let id = UUID()
        try LocalPersistence.transaction(context) { writer in
            writer.insert(AIConversation(id: id, accountScopeKey: accountScope, games: games, draft: draft))
        }
        return try LocalPersistence.conversation(id, in: context)
    }

    static func migrateLegacyConversations(to scope: String, games: [GameRecord],
                                           in context: ModelContext) throws {
        guard !scope.isEmpty, AccountScope.unambiguousArchiveScopeKey(for: games) == scope else { return }
        try LocalPersistence.transaction(context) { writer in
            let legacy = try writer.fetch(FetchDescriptor<AIConversation>()).filter { $0.accountScopeKey.isEmpty }
            let migratedIDs = Set(legacy.map(\.id))
            guard !migratedIDs.isEmpty else { return }
            let migratedAt = Date.now
            for conversation in legacy {
                conversation.accountScopeKey = scope
                conversation.updatedAt = migratedAt
            }
            for plan in try writer.fetch(FetchDescriptor<SavedGamePlan>()) where plan.accountScopeKey.isEmpty {
                guard let sourceID = UUID(uuidString: plan.sourceConversationID), migratedIDs.contains(sourceID) else { continue }
                plan.accountScopeKey = scope
                plan.updatedAt = migratedAt
            }
        }
    }
}
