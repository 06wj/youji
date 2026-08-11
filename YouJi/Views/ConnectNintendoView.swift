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
            connectionIntro
            .background(YJColor.paper)
            .navigationTitle("连接 Switch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } } }
            .alert("连接失败", isPresented: Binding(get: { coordinator.errorMessage != nil }, set: { if !$0 { coordinator.errorMessage = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(coordinator.errorMessage ?? "未知错误") }
            .overlay {
                if coordinator.isSyncing {
                    ProgressView("正在读取游玩记录…")
                        .padding(24)
                        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }

    private var connectionIntro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30).fill(YJColor.ink).frame(height: 215)
                    Circle().stroke(YJColor.lime, lineWidth: 14).frame(width: 106, height: 106).offset(x: 96, y: -52)
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "gamecontroller.fill").font(.system(size: 40)).foregroundStyle(YJColor.lime)
                        Text("把 Switch 的每次冒险，\n带回游迹。")
                            .font(.system(size: 30, weight: .black, design: .rounded)).foregroundStyle(.white)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(28)
                }
                VStack(alignment: .leading, spacing: 15) {
                    Label("在 Nintendo 官方页面完成登录", systemImage: "lock.shield.fill")
                    Label("读取全部游戏总时长与近 7 天明细", systemImage: "clock.arrow.circlepath")
                    Label("长期会话仅保存在本机 Keychain", systemImage: "iphone.and.arrow.forward")
                }.font(.subheadline.weight(.semibold))
                Text("Nintendo Account 需要已关联 Switch / Switch 2 的主机用户。该接入使用 Nintendo Store App 的非公开接口，可能因接口版本调整而需要更新。")
                    .font(.footnote).foregroundStyle(YJColor.muted).lineSpacing(4)
                Button {
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
                                coordinator.errorMessage = error.localizedDescription
                            }
                        case .failure(let error):
                            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                                coordinator.errorMessage = error.localizedDescription
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
                .disabled(isAuthorizing)
                .buttonStyle(.plain).font(.headline).foregroundStyle(.white).background(YJColor.ink, in: Capsule())
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
