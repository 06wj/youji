import SwiftData
import SwiftUI

@main
struct YouJiApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: GameRecord.self,
                PlaySnapshot.self,
                DailyPlayActivity.self,
                AIConversation.self,
                AIProfileResult.self,
                SavedGamePlan.self
            )
        } catch {
            fatalError("无法初始化本地数据库：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screenshotRoute = ScreenshotRoute.launchRoute {
                ScreenshotRouteView(route: screenshotRoute)
                    .preferredColorScheme(.light)
            } else {
                DashboardView()
                    .preferredColorScheme(.light)
            }
            #else
            DashboardView()
                .preferredColorScheme(.light)
            #endif
        }
        .modelContainer(container)
    }
}
