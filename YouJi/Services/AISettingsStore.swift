import Foundation

enum AISettingsStore {
    private static let apiKeyAccount = "ai-analysis-api-key"
    private static let modelNameKey = "ai-analysis-model-name"
    static let defaultModelName = "deepseek-r1"

    static var apiKey: String {
        KeychainStore.read(account: apiKeyAccount) ?? ""
    }

    static var modelName: String {
        let value = UserDefaults.standard.string(forKey: modelNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultModelName : value
    }

    static var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelName.isEmpty
    }

    static func save(apiKey: String, modelName: String) throws {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanKey.isEmpty {
            KeychainStore.delete(account: apiKeyAccount)
        } else {
            try KeychainStore.save(cleanKey, account: apiKeyAccount)
        }
        UserDefaults.standard.set(cleanModel.isEmpty ? defaultModelName : cleanModel, forKey: modelNameKey)
    }
}
