import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var apiKey: String
    @State private var modelName: String
    @State private var imageModelName: String
    @State private var showsAdvanced: Bool
    @State private var testTask: Task<Void, Never>?
    @State private var connectionSucceeded = false
    @State private var saved = false
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var connectionMessage: String?
    @State private var reminderEnabled = UserDefaults.standard.bool(forKey: "weekly-sync-reminder-enabled")
    let sync: SyncCoordinator?
    let prioritizesAIConfiguration: Bool
    let onConfigured: (() -> Void)?

    init(sync: SyncCoordinator? = nil, prioritizesAIConfiguration: Bool = false, onConfigured: (() -> Void)? = nil) {
        self.sync = sync
        self.prioritizesAIConfiguration = prioritizesAIConfiguration
        self.onConfigured = onConfigured
        _apiKey = State(initialValue: AISettingsStore.apiKey)
        _modelName = State(initialValue: AISettingsStore.modelName)
        _imageModelName = State(initialValue: AISettingsStore.imageModelName)
        _showsAdvanced = State(initialValue: false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    intro
                    if prioritizesAIConfiguration {
                        credentials
                        product
                    } else {
                        product
                        credentials
                    }
                    privacy
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .background(YJColor.paper.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
            }
            .alert("保存失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            .alert("AI 服务", isPresented: Binding(
                get: { connectionMessage != nil },
                set: { if !$0 { connectionMessage = nil } }
            )) {
                if connectionSucceeded && prioritizesAIConfiguration {
                    Button("返回继续") { finishConfiguration() }
                } else {
                    Button("知道了", role: .cancel) {}
                }
            } message: { Text(connectionMessage ?? "") }
            .onDisappear { testTask?.cancel() }
        }
    }

    private var intro: some View {
        HStack(spacing: 14) {
            Image(systemName: prioritizesAIConfiguration ? "sparkles" : "slider.horizontal.3")
                .font(.title2.bold()).foregroundStyle(YJColor.lime)
                .frame(width: 52, height: 52)
                .background(YJColor.lime.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(prioritizesAIConfiguration ? "配置游戏大脑" : "管理游迹").font(.headline)
                Text(prioritizesAIConfiguration
                     ? "填写 OpenAI 密钥，保存后回到刚才的任务。"
                     : "管理同步提醒、本地数据、隐私与 AI 服务。")
                    .font(.caption).foregroundStyle(YJColor.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(17)
        .youjiCard()
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI SERVICE / 模型服务")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(1.2).foregroundStyle(YJColor.muted)

            Label("OpenAI", systemImage: "sparkles").font(.headline)
            Text("聊天、游戏分析和绘图均使用你的 OpenAI API 账号，费用计入该账号的 API 用量。")
                .font(.caption).foregroundStyle(YJColor.muted).lineSpacing(3)

            VStack(alignment: .leading, spacing: 7) {
                Text("API Key").font(.caption.bold()).foregroundStyle(YJColor.muted)
                SecureField("粘贴 OpenAI API Key", text: $apiKey)
                    .disabled(isTesting)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(13).background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
                Text("只存入这台设备的系统钥匙串，不随备份导出。")
                    .font(.caption2).foregroundStyle(YJColor.muted)
            }

            DisclosureGroup("文字与绘图模型", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("文字模型").font(.caption.bold()).foregroundStyle(YJColor.muted)
                        TextField(AISettingsStore.defaultModelName, text: $modelName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(13).background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
                        Text("用于聊天、分析及对话标题；需支持 Responses API 的绘图工具。")
                            .font(.caption2).foregroundStyle(YJColor.muted)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("绘图模型").font(.caption.bold()).foregroundStyle(YJColor.muted)
                        TextField(AISettingsStore.defaultImageModelName, text: $imageModelName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(13).background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
                        Text("用于聊天画图和分析画像，需要账号具有该模型的使用权限。")
                            .font(.caption2).foregroundStyle(YJColor.muted)
                    }
                    Link("查看 OpenAI 模型", destination: URL(string: "https://developers.openai.com/api/docs/models")!)
                }.padding(.top, 10)
            }
            .font(.subheadline.bold()).disabled(isTesting)

            Text("发送至 api.openai.com")
                .font(.caption2).foregroundStyle(YJColor.muted)

            VStack(spacing: 10) {
                Button(action: save) {
                    Label(saved ? "已保存" : prioritizesAIConfiguration ? "保存并返回" : "保存配置",
                          systemImage: saved ? "checkmark" : "tray.and.arrow.down")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(YJPrimaryButtonStyle()).disabled(isTesting)

                Button(action: testConnection) {
                    HStack {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text(isTesting ? "测试中…" : "保存并测试连接")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(isTesting)
                Text("保存配置不会发送游戏数据。测试会向 OpenAI 发送一条简短文字消息，可能消耗少量额度；不会生成图片。")
                    .font(.caption2).foregroundStyle(YJColor.muted)
            }

            if !apiKey.isEmpty {
                Button(role: .destructive) {
                    AISettingsStore.clearAPIKey()
                    apiKey = ""
                    saved = false
                } label: {
                    Label("清除这台设备上的 AI API Key", systemImage: "key.slash")
                        .font(.subheadline.bold())
                }
                .disabled(isTesting)
            }
        }
        .onChange(of: apiKey) { _, _ in saved = false }
        .onChange(of: modelName) { _, _ in saved = false }
        .onChange(of: imageModelName) { _, _ in saved = false }
        .padding(17)
        .youjiCard()
    }

    private var product: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PLAYLOG / 产品与数据")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(1.2).foregroundStyle(YJColor.muted)
            Toggle("每周日提醒我主动同步", isOn: $reminderEnabled)
                .onChange(of: reminderEnabled) { _, enabled in
                    UserDefaults.standard.set(enabled, forKey: "weekly-sync-reminder-enabled")
                    if enabled {
                        Task {
                            do { try await SyncReminderService.scheduleWeekly() }
                            catch {
                                reminderEnabled = false
                                UserDefaults.standard.set(false, forKey: "weekly-sync-reminder-enabled")
                                errorMessage = error.localizedDescription
                            }
                        }
                    } else {
                        SyncReminderService.cancel()
                    }
                }
            Text("提醒只提示你打开游迹，不会在后台自动同步。")
                .font(.caption2).foregroundStyle(YJColor.muted)
            Divider()
            NavigationLink {
                DataManagementView(sync: sync)
            } label: {
                Label("备份、恢复与数据管理", systemImage: "externaldrive.fill")
                    .font(.subheadline.bold())
            }
            NavigationLink {
                PrivacyInfoView()
            } label: {
                Label("数据与隐私说明", systemImage: "hand.raised.fill")
                    .font(.subheadline.bold())
            }
            ShareLink(item: ProductDataService.diagnostics(modelContext: modelContext)) {
                Label("分享安全诊断摘要", systemImage: "stethoscope")
                    .font(.subheadline.bold())
            }
            Link(destination: URL(string: "https://github.com/06wj/youji-ios/issues/new")!) {
                Label("发送产品反馈", systemImage: "envelope.fill")
                    .font(.subheadline.bold())
            }
        }
        .foregroundStyle(YJColor.ink)
        .padding(17)
        .youjiCard()
    }

    private var privacy: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(YJColor.purple)
            Text("API Key 只保存在这台设备。仅在你主动分析、发送或生成图片时向 OpenAI 发送必要内容。生成的图片保存在本机，并随完整备份导出。")
                .font(.caption).foregroundStyle(YJColor.muted).lineSpacing(3)
        }
        .padding(16)
        .background(YJColor.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func save() {
        do {
            try persistConfiguration()
            saved = true
            if prioritizesAIConfiguration { finishConfiguration() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistConfiguration() throws {
        try AISettingsStore.save(apiKey: apiKey, modelName: modelName, imageModelName: imageModelName)
        apiKey = AISettingsStore.apiKey
        modelName = AISettingsStore.modelName
        imageModelName = AISettingsStore.imageModelName
    }

    private func finishConfiguration() {
        onConfigured?()
        dismiss()
    }

    private func testConnection() {
        do { try persistConfiguration() }
        catch {
            errorMessage = error.localizedDescription
            return
        }
        isTesting = true
        connectionSucceeded = false
        testTask = Task {
            defer { isTesting = false }
            do {
                try await AIAnalysisClient.shared.testConnection(apiKey: AISettingsStore.apiKey, model: AISettingsStore.modelName)
                guard !Task.isCancelled else { return }
                connectionSucceeded = true
                connectionMessage = "连接成功。返回后可继续刚才的任务，生成或发送仍由你决定。"
            } catch {
                guard !Task.isCancelled else { return }
                connectionMessage = error.localizedDescription
            }
        }
    }
}
