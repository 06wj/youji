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
                if let progress = coordinator.syncProgress, progress.platform == .playStation {
                    ScrollView {
                        PlatformSyncProgressCard(progress: progress, onBrowse: { dismiss() })
                            .padding(20)
                    }
                } else if showBrowser {
                    PlayStationLoginWebView(credentialRequest: $credentialRequest) { result in
                        switch result {
                        case .success(let npsso):
                            Task {
                                await coordinator.finishPlayStationAuthorization(npsso: npsso, modelContext: modelContext)
                                if coordinator.errorMessage == nil { dismiss() }
                            }
                        case .failure(let error):
                            coordinator.reportConnectionError(error, platform: .playStation)
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
                ToolbarItem(placement: .topBarLeading) { Button(coordinator.isSyncing ? "返回游戏库" : "取消") { dismiss() } }
                if showBrowser && !coordinator.isSyncing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("登录完成") { credentialRequest += 1 }.fontWeight(.semibold)
                    }
                }
            }
            .alert("连接尚未完成", isPresented: Binding(get: { coordinator.errorMessage != nil && coordinator.syncIssue?.platform == .playStation }, set: { if !$0 { coordinator.errorMessage = nil } })) {
                Button(coordinator.issue(for: .playStation)?.recovery == .retry && coordinator.isPlayStationConnected ? "重试同步" : "重新登录") {
                    if coordinator.issue(for: .playStation)?.recovery == .retry && coordinator.isPlayStationConnected {
                        Task {
                            try? await coordinator.syncPlayStation(modelContext: modelContext)
                            if coordinator.errorMessage == nil { dismiss() }
                        }
                    } else {
                        coordinator.clearIssue(for: .playStation)
                        showBrowser = false
                    }
                }
                Button("知道了", role: .cancel) {}
            } message: {
                Text(coordinator.errorMessage ?? "未知错误")
            }
            .onAppear { coordinator.errorMessage = nil }
        }
    }

    private var connectionIntro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                YJFeatureHeading(eyebrow: "PLAYSTATION / CONNECT", title: "每一座奖杯，\n都有你的故事。",
                                 subtitle: "把 PS4 与 PS5 的时光，一起放进游迹。", accent: YJColor.playStation)

                VStack(alignment: .leading, spacing: 15) {
                    Label("在 Sony 官方页面完成登录", systemImage: "lock.shield.fill")
                    Label("读取游戏名称、封面、总时长与最近游玩", systemImage: "clock.arrow.circlepath")
                    Label("登录信息仅保存在这台设备", systemImage: "iphone.and.arrow.forward")
                }.font(.subheadline.weight(.semibold))

                Text("进入页面完成 PlayStation 登录后，点右上角“登录完成”。游迹不会读取或保存你的密码。")
                    .font(.footnote).foregroundStyle(YJColor.muted).lineSpacing(4)

                Button {
                    coordinator.clearIssue(for: .playStation)
                    showBrowser = true
                } label: {
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

struct PlatformSyncProgressCard: View {
    let progress: PlatformSyncProgress
    var onBrowse: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(progress.platform.rawValue, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.bold()).foregroundStyle(YJColor.platform(progress.platform))
            Text(progress.title).font(.title2.bold()).foregroundStyle(YJColor.ink)
            Text(progress.detail).font(.subheadline).foregroundStyle(YJColor.muted)
            if let completed = progress.completed, let total = progress.total, total > 0 {
                ProgressView(value: Double(min(completed, total)), total: Double(total))
                    .tint(YJColor.platform(progress.platform))
                    .accessibilityLabel("奖杯处理进度")
                    .accessibilityValue("已处理 \(completed) 项，共 \(total) 项")
                Text("奖杯 \(completed) / \(total)")
                    .font(.caption.monospacedDigit()).foregroundStyle(YJColor.muted)
            } else {
                ProgressView().tint(YJColor.platform(progress.platform))
            }
            if progress.gameListSaved, let onBrowse {
                Button("先浏览游戏", action: onBrowse).buttonStyle(YJPrimaryButtonStyle())
                Text("返回游戏库后，本次导入会继续。")
                    .font(.caption).foregroundStyle(YJColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .youjiCard()
    }
}

private struct PlayStationLoginWebView: UIViewRepresentable {
    @Binding var credentialRequest: Int
    let completion: (Result<String, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
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
            guard !readingCredential else { return }
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
