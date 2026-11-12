import Foundation

enum AISettingsStore {
    private static let apiKeyAccount = "openai-api-key"
    private static let modelNameKey = "openai-text-model"
    private static let imageModelNameKey = "openai-image-model"
    static let defaultModelName = "gpt-6-luna"
    static let defaultImageModelName = "gpt-image-2.6-flare"
    static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    static let imagesURL = URL(string: "https://api.openai.com/v1/images/generations")!

    // Provider-scoped storage prevents an old service's key or model from being
    // silently sent to OpenAI after updating the app.
    static var apiKey: String { KeychainStore.read(account: apiKeyAccount) ?? "" }
    static var modelName: String { model(forKey: modelNameKey, fallback: defaultModelName) }
    static var imageModelName: String { model(forKey: imageModelNameKey, fallback: defaultImageModelName) }

    static var isConfigured: Bool {
        (try? validate(apiKey: apiKey, modelName: modelName, imageModelName: imageModelName)) != nil
    }

    private static func model(forKey key: String, fallback: String) -> String {
        let value = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }

    static func validate(apiKey: String, modelName: String, imageModelName: String) throws {
        try validateRequest(apiKey: apiKey, modelName: modelName)
        try validateModel(imageModelName)
    }

    static func validateRequest(apiKey: String, modelName: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AISettingsError.missingAPIKey }
        guard key.count <= 1_024, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw AISettingsError.invalidAPIKey
        }
        try validateModel(modelName)
    }

    private static func validateModel(_ model: String) throws {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw AISettingsError.invalidModel
        }
    }

    static func save(apiKey: String, modelName: String, imageModelName: String) throws {
        try validate(apiKey: apiKey, modelName: modelName, imageModelName: imageModelName)
        try KeychainStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: apiKeyAccount)
        UserDefaults.standard.set(modelName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelNameKey)
        UserDefaults.standard.set(imageModelName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: imageModelNameKey)
        removeLegacyConfiguration()
    }

    static func clearAPIKey() {
        KeychainStore.delete(account: apiKeyAccount)
        removeLegacyConfiguration()
    }

    static func removeLegacyConfiguration() {
        KeychainStore.delete(account: "ai-analysis-api-key")
        UserDefaults.standard.removeObject(forKey: "ai-analysis-model-name")
        UserDefaults.standard.removeObject(forKey: "ai-analysis-endpoint")
    }
}

enum AISettingsError: LocalizedError {
    case missingAPIKey, invalidAPIKey, invalidModel

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "请先填写 OpenAI API Key。密钥只会保存在这台设备。"
        case .invalidAPIKey: "API Key 格式不正确，请重新粘贴完整密钥，不要包含空格或换行。"
        case .invalidModel: "请填写你的 OpenAI 账号可用的完整模型名称，不要包含空格或换行。"
        }
    }
}
