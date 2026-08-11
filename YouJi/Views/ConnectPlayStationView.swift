import SwiftData
import SwiftUI
import WebKit

struct ConnectPlayStationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var coordinator: SyncCoordinator
    @State private var showBrowser = false
    @State private var credentialRequest = 0

    var body: some View {
        NavigationStack {
            Group {
                if showBrowser {
                    PlayStationLoginWebView(credentialRequest: $credentialRequest) { result in
                        switch result {
                        case .success(let npsso):
                            Task {
                                await coordinator.finishPlayStationAuthorization(npsso: npsso, modelContext: modelContext)
                                if coordinator.errorMessage == nil { dismiss() }
                            }
                        case .failure(let error):
                            coordinator.errorMessage = error.localizedDescription
                        }
                    }
                } else {
                    connectionIntro
                }
            }
            .background(YJColor.paper)
            .navigationTitle("连接 PlayStation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                if showBrowser {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("已登录，读取") { credentialRequest += 1 }.fontWeight(.semibold)
                    }
                }
            }
            .alert("连接失败", isPresented: Binding(get: { coordinator.errorMessage != nil }, set: { if !$0 { coordinator.errorMessage = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(coordinator.errorMessage ?? "未知错误")
            }
            .overlay {
                if coordinator.isSyncing {
                    ProgressView("正在读取 PlayStation 记录…")
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
                    RoundedRectangle(cornerRadius: 30).fill(Color(red: 0.02, green: 0.18, blue: 0.48)).frame(height: 215)
                    Circle().stroke(.white.opacity(0.17), lineWidth: 14).frame(width: 110, height: 110).offset(x: 98, y: -52)
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "playstation.logo").font(.system(size: 42)).foregroundStyle(.white)
                        Text("PS4 与 PS5 的时光，\n一起放进游迹。")
                            .font(.system(size: 30, weight: .black, design: .rounded)).foregroundStyle(.white)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(28)
                }

                VStack(alignment: .leading, spacing: 15) {
                    Label("在 Sony 官方页面完成登录", systemImage: "lock.shield.fill")
                    Label("读取游戏名称、封面、总时长与最近游玩", systemImage: "clock.arrow.circlepath")
                    Label("刷新令牌仅保存在本机 Keychain", systemImage: "iphone.and.arrow.forward")
                }.font(.subheadline.weight(.semibold))

                Text("进入页面后完成 PlayStation 登录，再点右上角“已登录，读取”。游迹会在同一个网页会话中读取登录凭据并立即换取访问令牌，不会读取或保存密码。")
                    .font(.footnote).foregroundStyle(YJColor.muted).lineSpacing(4)

                Button { showBrowser = true } label: {
                    Label("登录 PlayStation Network", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(.white)
                .background(Color(red: 0.02, green: 0.18, blue: 0.48), in: Capsule())
            }.padding(20)
        }
    }
}

private struct PlayStationLoginWebView: UIViewRepresentable {
    @Binding var credentialRequest: Int
    let completion: (Result<String, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.lastCredentialRequest = credentialRequest
        webView.load(URLRequest(url: URL(string: "https://www.playstation.com/acct/management/")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard credentialRequest != context.coordinator.lastCredentialRequest else { return }
        context.coordinator.lastCredentialRequest = credentialRequest
        context.coordinator.readCredential(from: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PlayStationLoginWebView
        var lastCredentialRequest = 0
        var readingCredential = false

        init(_ parent: PlayStationLoginWebView) { self.parent = parent }

        func readCredential(from webView: WKWebView) {
            readingCredential = true
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                if let npsso = cookies.first(where: { $0.name.lowercased() == "npsso" })?.value,
                   !npsso.isEmpty {
                    self.readingCredential = false
                    self.parent.completion(.success(npsso))
                    return
                }
                webView.load(URLRequest(url: URL(string: "https://ca.account.sony.com/api/v1/ssocookie")!))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard readingCredential,
                  webView.url?.host == "ca.account.sony.com",
                  webView.url?.path == "/api/v1/ssocookie" else { return }
            readingCredential = false
            webView.evaluateJavaScript("document.body ? document.body.innerText : document.documentElement.innerText") { value, error in
                if let error {
                    self.parent.completion(.failure(error))
                    return
                }
                guard let text = value as? String,
                      let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                      let response = try? JSONDecoder().decode(NPSSOResponse.self, from: data),
                      !response.npsso.isEmpty else {
                    self.parent.completion(.failure(PlayStationSyncError.invalidNPSSO))
                    return
                }
                self.parent.completion(.success(response.npsso))
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if readingCredential {
                readingCredential = false
                parent.completion(.failure(error))
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if readingCredential {
                readingCredential = false
                parent.completion(.failure(error))
            }
        }
    }
}

private struct NPSSOResponse: Decodable {
    let npsso: String
}
