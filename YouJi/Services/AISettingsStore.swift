import Foundation

enum AISettingsStore {
    private static let apiKeyAccount = "ai-analysis-api-key"
    private static let modelNameKey = "ai-analysis-model-name"
    private static let endpointKey = "ai-analysis-endpoint"
    static let defaultModelName = "deepseek-r1"
    static let defaultEndpoint = "https://api.celitech.com.cn/v1/chat/completions"

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

    static var endpointString: String {
        let value = UserDefaults.standard.string(forKey: endpointKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultEndpoint : value
    }

    static var endpointURL: URL {
        URL(string: endpointString) ?? URL(string: defaultEndpoint)!
    }

    static func save(apiKey: String, modelName: String, endpoint: String) throws {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpointURL = URL(string: cleanEndpoint.isEmpty ? defaultEndpoint : cleanEndpoint),
              endpointURL.scheme == "https" else {
            throw AISettingsError.invalidEndpoint
        }
        if cleanKey.isEmpty {
            KeychainStore.delete(account: apiKeyAccount)
        } else {
            try KeychainStore.save(cleanKey, account: apiKeyAccount)
        }
        UserDefaults.standard.set(cleanModel.isEmpty ? defaultModelName : cleanModel, forKey: modelNameKey)
        UserDefaults.standard.set(endpointURL.absoluteString, forKey: endpointKey)
    }
}

enum AISettingsError: LocalizedError {
    case invalidEndpoint

    var errorDescription: String? { "模型接口必须是有效的 HTTPS 地址。" }
}
