import SwiftData
import SwiftUI

@main
struct YouJiApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: GameRecord.self, PlaySnapshot.self, AIConversation.self)
        } catch {
            fatalError("无法初始化本地数据库：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .preferredColorScheme(.light)
        }
        .modelContainer(container)
    }
}
