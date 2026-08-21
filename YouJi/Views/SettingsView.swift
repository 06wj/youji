import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var apiKey: String
    @State private var modelName: String
    @State private var endpoint: String
    @State private var saved = false
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var connectionMessage: String?
    @State private var reminderEnabled = UserDefaults.standard.bool(forKey: "weekly-sync-reminder-enabled")
    let sync: SyncCoordinator?
    let prioritizesAIConfiguration: Bool

    init(sync: SyncCoordinator? = nil, prioritizesAIConfiguration: Bool = false) {
        self.sync = sync
        self.prioritizesAIConfiguration = prioritizesAIConfiguration
        _apiKey = State(initialValue: AISettingsStore.apiKey)
        _modelName = State(initialValue: AISettingsStore.modelName)
        _endpoint = State(initialValue: AISettingsStore.endpointString)
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
            )) { Button("知道了", role: .cancel) {} } message: { Text(connectionMessage ?? "") }
        }
    }

    private var intro: some View {
        HStack(spacing: 14) {
            Image(systemName: prioritizesAIConfiguration ? "sparkles" : "slider.horizontal.3")
                .font(.title2.bold()).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(YJColor.purple, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(prioritizesAIConfiguration ? "配置游戏大脑" : "管理游迹").font(.headline)
                Text(prioritizesAIConfiguration
                     ? "使用你自己的模型配置分析筛选后的本地游戏记录。"
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

            VStack(alignment: .leading, spacing: 7) {
                Text("API Key").font(.caption.bold()).foregroundStyle(YJColor.muted)
                SecureField("sk-…", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(13).background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("接口地址").font(.caption.bold()).foregroundStyle(YJColor.muted)
                TextField(AISettingsStore.defaultEndpoint, text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(13).background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
                Text(endpoint == AISettingsStore.defaultEndpoint ? "当前使用策量智算的 OpenAI 兼容接口。" : "当前使用你填写的 OpenAI Chat Completions 兼容接口。")
                    .font(.caption2).foregroundStyle(YJColor.muted)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("模型名称").font(.caption.bold()).foregroundStyle(YJColor.muted)
                TextField(AISettingsStore.defaultModelName, text: $modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(13).background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
                Text("必须使用服务支持的标准模型名称。")
                    .font(.caption2).foregroundStyle(YJColor.muted)
            }

            HStack(spacing: 10) {
                Button(action: save) {
                    Label(saved ? "已保存" : "保存配置", systemImage: saved ? "checkmark" : "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(action: testConnection) {
                    HStack {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text(isTesting ? "测试中…" : "保存并测试")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(YJColor.ink)
                .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !apiKey.isEmpty {
                Button(role: .destructive) {
                    do {
                        try AISettingsStore.save(apiKey: "", modelName: modelName, endpoint: endpoint)
                        apiKey = ""
                        saved = true
                    } catch { errorMessage = error.localizedDescription }
                } label: {
                    Label("清除本机 AI API Key", systemImage: "key.slash")
                        .font(.subheadline.bold())
                }
            }

        }
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
            Text("API Key 只保存在本机 Keychain。发起分析或聊天时，只会向模型服务发送必要的游戏信息和当前对话。")
                .font(.caption).foregroundStyle(YJColor.muted).lineSpacing(3)
        }
        .padding(16)
        .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private func save() {
        do {
            try AISettingsStore.save(apiKey: apiKey, modelName: modelName, endpoint: endpoint)
            apiKey = AISettingsStore.apiKey
            modelName = AISettingsStore.modelName
            endpoint = AISettingsStore.endpointString
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testConnection() {
        do {
            try AISettingsStore.save(apiKey: apiKey, modelName: modelName, endpoint: endpoint)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isTesting = true
        Task {
            defer { isTesting = false }
            do {
                try await AIAnalysisClient.shared.testConnection(apiKey: AISettingsStore.apiKey, model: AISettingsStore.modelName)
                connectionMessage = "连接成功，模型配置可以使用。"
            } catch {
                connectionMessage = error.localizedDescription
            }
        }
    }
}
