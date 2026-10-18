import AuthenticationServices
import SwiftData
import SwiftUI

struct ConnectNintendoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var coordinator: SyncCoordinator
    @State private var oauth = NintendoOAuthSession.make()
    @StateObject private var webAuthenticator = NintendoWebAuthenticator()
    @State private var isAuthorizing = false

    var body: some View {
        NavigationStack {
            Group {
                if let progress = coordinator.syncProgress, progress.platform == .switchConsole {
                    ScrollView {
                        PlatformSyncProgressCard(progress: progress, onBrowse: { dismiss() })
                            .padding(20)
                    }
                } else {
                    connectionIntro
                }
            }
            .background(YJColor.paper)
            .navigationTitle("连接 Switch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(coordinator.isSyncing ? "返回游戏库" : "取消") { dismiss() } } }
            .alert("连接尚未完成", isPresented: Binding(get: { coordinator.errorMessage != nil && coordinator.syncIssue?.platform == .switchConsole }, set: { if !$0 { coordinator.errorMessage = nil } })) {
                if coordinator.issue(for: .switchConsole)?.recovery == .retry && coordinator.isNintendoConnected {
                    Button("重试同步") {
                        Task {
                            try? await coordinator.syncNintendo(modelContext: modelContext)
                            if coordinator.errorMessage == nil { dismiss() }
                        }
                    }
                }
                Button("知道了", role: .cancel) {}
            } message: { Text(coordinator.errorMessage ?? "未知错误") }
            .onAppear { coordinator.errorMessage = nil }
        }
    }

    private var connectionIntro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                YJFeatureHeading(eyebrow: "NINTENDO SWITCH / CONNECT", title: "下一次冒险，\n也要好好记住。",
                                 subtitle: "把 Switch 的每次探索，带回游迹。", artwork: "TwilightCamp", accent: YJColor.nintendo)

                VStack(alignment: .leading, spacing: 15) {
                    Label("在 Nintendo 官方页面完成登录", systemImage: "lock.shield.fill")
                    Label("读取全部游戏总时长与近 7 天明细", systemImage: "clock.arrow.circlepath")
                    Label("登录信息仅保存在这台设备", systemImage: "iphone.and.arrow.forward")
                }.font(.subheadline.weight(.semibold))
                Text("Nintendo Account 需要已关联 Switch 或 Switch 2 的主机用户。")
                    .font(.footnote).foregroundStyle(YJColor.muted).lineSpacing(4)
                Button {
                    coordinator.clearIssue(for: .switchConsole)
                    oauth = .make()
                    let currentOAuth = oauth
                    isAuthorizing = true
                    webAuthenticator.start(oauth: currentOAuth) { result in
                        isAuthorizing = false
                        switch result {
                        case .success(let callbackURL):
                            do {
                                let code = try currentOAuth.parseCallback(callbackURL)
                                Task {
                                    await coordinator.finishAuthorization(
                                        code: code,
                                        verifier: currentOAuth.verifier,
                                        modelContext: modelContext
                                    )
                                    if coordinator.errorMessage == nil { dismiss() }
                                }
                            } catch {
                                coordinator.reportConnectionError(error, platform: .switchConsole)
                            }
                        case .failure(let error):
                            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                                coordinator.reportConnectionError(error, platform: .switchConsole)
                            }
                        }
                    }
                } label: {
                    if isAuthorizing {
                        ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 15)
                    } else {
                        Label("登录 Nintendo Account", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                    }
                }
                .disabled(isAuthorizing || coordinator.isSyncing)
                .buttonStyle(.plain).font(.headline).foregroundStyle(.white).background(Color(red: 0.68, green: 0.12, blue: 0.17), in: RoundedRectangle(cornerRadius: 14))
            }.padding(20)
        }
    }
}

@MainActor
private final class NintendoWebAuthenticator: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(oauth: NintendoOAuthSession, completion: @escaping (Result<URL, Error>) -> Void) {
        session?.cancel()
        let authenticationSession = ASWebAuthenticationSession(
            url: oauth.authorizationURL,
            callbackURLScheme: "npf\(NintendoOAuthSession.clientID)"
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.session = nil
                if let callbackURL {
                    completion(.success(callbackURL))
                } else {
                    completion(.failure(error ?? NintendoAuthError.missingCode))
                }
            }
        }
        authenticationSession.presentationContextProvider = self
        authenticationSession.prefersEphemeralWebBrowserSession = false
        session = authenticationSession
        if !authenticationSession.start() {
            session = nil
            completion(.failure(NintendoAuthError.server("无法打开 Nintendo 登录页面，请重试")))
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
