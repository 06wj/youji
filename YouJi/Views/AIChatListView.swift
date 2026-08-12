import SwiftData
import SwiftUI

struct AIChatListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIConversation.updatedAt, order: .reverse) private var conversations: [AIConversation]

    let games: [GameRecord]

    @State private var path: [UUID] = []
    @State private var conversationToDelete: AIConversation?

    private var chatGames: [AIAnalysisGame] {
        games
            .filter { $0.totalMinutes > AIPrompts.chatMinimumMinutes }
            .sorted {
                if $0.totalMinutes == $1.totalMinutes {
                    return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
                }
                return $0.totalMinutes > $1.totalMinutes
            }
            .map { game in
                AIAnalysisGame(
                    platform: game.platform.shortName,
                    title: game.title,
                    totalMinutes: game.totalMinutes,
                    trophyRatio: game.platform == .playStation && game.trophiesDefined > 0
                        ? trophyText(game)
                        : nil
                )
            }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if conversations.isEmpty {
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
                    Button(action: createConversation) {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(chatGames.isEmpty)
                    .accessibilityLabel("新建对话")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let conversation = conversations.first(where: { $0.id == id }) {
                    AIChatView(conversation: conversation)
                } else {
                    ContentUnavailableView("对话不存在", systemImage: "message.slash")
                }
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
            ForEach(conversations) { conversation in
                NavigationLink(value: conversation.id) {
                    conversationRow(conversation)
                }
                .listRowBackground(Color.white.opacity(0.72))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("删除", role: .destructive) {
                        conversationToDelete = conversation
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func conversationRow(_ conversation: AIConversation) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "message.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(YJColor.purple, in: RoundedRectangle(cornerRadius: 12))
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
        ContentUnavailableView {
            Label("还没有对话", systemImage: "bubble.left.and.bubble.right")
        } description: {
            if chatGames.isEmpty {
                Text("至少需要一款游玩超过 1 小时的游戏才能开始聊天。")
            } else {
                Text("新建一段对话，游戏大脑会记住你们聊过的内容。")
            }
        } actions: {
            Button("开始聊天", action: createConversation)
                .buttonStyle(.borderedProminent)
                .tint(YJColor.ink)
                .disabled(chatGames.isEmpty)
        }
    }

    private func createConversation() {
        guard !chatGames.isEmpty else { return }
        let conversation = AIConversation(games: chatGames)
        modelContext.insert(conversation)
        try? modelContext.save()
        path.append(conversation.id)
    }

    private func deleteConversation() {
        guard let conversationToDelete else { return }
        modelContext.delete(conversationToDelete)
        try? modelContext.save()
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
