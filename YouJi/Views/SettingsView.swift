import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var apiKey: String
    @State private var modelName: String
    @State private var endpoint: String
    @State private var servicePreset: AIServicePreset
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
        _endpoint = State(initialValue: AISettingsStore.endpointString)
        let usesPreset = AISettingsStore.endpointString == AISettingsStore.defaultEndpoint
        _servicePreset = State(initialValue: usesPreset ? .celitech : .custom)
        _showsAdvanced = State(initialValue: !usesPreset || AISettingsStore.modelName != AISettingsStore.defaultModelName)
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
                     ? "选好服务、填写密钥，保存后回到刚才的任务。"
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

            Picker("选择服务", selection: $servicePreset) {
                ForEach(AIServicePreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .tint(YJColor.lime).disabled(isTesting)
            .onChange(of: servicePreset) { _, value in
                saved = false
                if value == .celitech {
                    if endpoint != AISettingsStore.defaultEndpoint { apiKey = "" }
                    endpoint = AISettingsStore.defaultEndpoint
                    modelName = AISettingsStore.defaultModelName
                } else {
                    showsAdvanced = true
                }
            }

            Text(servicePreset == .celitech
                 ? "已填好现有服务预设。你需要该服务自己的 API Key；账户和用量由服务商管理。"
                 : "使用你自己的 HTTPS Chat Completions 兼容服务，填写完整接口地址及模型名称。")
                .font(.caption).foregroundStyle(YJColor.muted).lineSpacing(3)

            VStack(alignment: .leading, spacing: 7) {
                Text("API Key").font(.caption.bold()).foregroundStyle(YJColor.muted)
                SecureField("粘贴所选服务的 API Key", text: $apiKey)
                    .disabled(isTesting)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(13).background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
                Text("只存入这台设备的系统钥匙串，不随备份导出。")
                    .font(.caption2).foregroundStyle(YJColor.muted)
            }

            DisclosureGroup("接口与模型（高级）", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("完整接口地址").font(.caption.bold()).foregroundStyle(YJColor.muted)
                        TextField(AISettingsStore.defaultEndpoint, text: $endpoint, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled().keyboardType(.URL)
                            .padding(13).background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
                        Text("通常以 /v1/chat/completions 结尾；不要只填写网站首页，也不要把密钥放在地址中。")
                            .font(.caption2).foregroundStyle(YJColor.muted)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("模型名称").font(.caption.bold()).foregroundStyle(YJColor.muted)
                        TextField(AISettingsStore.defaultModelName, text: $modelName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(13).background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
                        Text("填写服务支持的标准名称，区分大小写。")
                            .font(.caption2).foregroundStyle(YJColor.muted)
                    }
                }.padding(.top, 10)
            }
            .font(.subheadline.bold()).disabled(isTesting)

            if let host = URLComponents(string: endpoint)?.host {
                Text("发送至 \(host) · 模型 \(modelName)")
                    .font(.caption2).foregroundStyle(YJColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                Text("保存配置不会发送游戏数据。测试会向所选服务发送一条简短测试消息，可能消耗少量额度。")
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
        .onChange(of: endpoint) { _, _ in saved = false }
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
            Text("API Key 只保存在这台设备。发起分析或聊天时，只会向模型服务发送必要的游戏信息和当前对话。")
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
        try AISettingsStore.save(apiKey: apiKey, modelName: modelName, endpoint: endpoint)
        apiKey = AISettingsStore.apiKey
        modelName = AISettingsStore.modelName
        endpoint = AISettingsStore.endpointString
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
