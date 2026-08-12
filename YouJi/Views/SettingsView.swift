import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String
    @State private var modelName: String
    @State private var saved = false
    @State private var errorMessage: String?

    init() {
        _apiKey = State(initialValue: AISettingsStore.apiKey)
        _modelName = State(initialValue: AISettingsStore.modelName)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    intro
                    credentials
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saved ? "已保存" : "保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private var intro: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2.bold()).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(YJColor.purple, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("AI 游戏人格").font(.headline)
                Text("使用你自己的模型配置分析筛选后的本地游戏记录。")
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
                Text("模型名称").font(.caption.bold()).foregroundStyle(YJColor.muted)
                TextField(AISettingsStore.defaultModelName, text: $modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(13).background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
                Text("必须使用服务支持的标准模型名称。")
                    .font(.caption2).foregroundStyle(YJColor.muted)
            }

        }
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
            try AISettingsStore.save(apiKey: apiKey, modelName: modelName)
            apiKey = AISettingsStore.apiKey
            modelName = AISettingsStore.modelName
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
