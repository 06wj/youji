import Foundation

enum AIServicePreset: String, CaseIterable {
    case celitech = "策量智算"
    case custom = "自定义兼容服务"
}

enum AISettingsStore {
    private static let apiKeyAccount = "ai-analysis-api-key"
    private static let modelNameKey = "ai-analysis-model-name"
    private static let endpointKey = "ai-analysis-endpoint"
    static let defaultModelName = "deepseek-r1"
    static let defaultEndpoint = "https://api.celitech.com.cn/v1/chat/completions"

    static var apiKey: String { KeychainStore.read(account: apiKeyAccount) ?? "" }

    static var modelName: String {
        let value = UserDefaults.standard.string(forKey: modelNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultModelName : value
    }

    static var isConfigured: Bool {
        (try? validate(apiKey: apiKey, modelName: modelName, endpoint: endpointString)) != nil
    }

    static var endpointString: String {
        let value = UserDefaults.standard.string(forKey: endpointKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultEndpoint : value
    }

    static var endpointURL: URL {
        get throws { try validatedEndpoint(endpointString) }
    }

    static func validatedEndpoint(_ endpoint: String) throws -> URL {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw AISettingsError.invalidEndpoint
        }
        return url
    }

    static func validate(apiKey: String, modelName: String, endpoint: String) throws -> URL {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw AISettingsError.missingAPIKey }
        guard cleanKey.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw AISettingsError.invalidAPIKey
        }
        guard !cleanModel.isEmpty, cleanModel.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw AISettingsError.invalidModel
        }
        return try validatedEndpoint(endpoint)
    }

    static func save(apiKey: String, modelName: String, endpoint: String) throws {
        let url = try validate(apiKey: apiKey, modelName: modelName, endpoint: endpoint)
        try KeychainStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: apiKeyAccount)
        UserDefaults.standard.set(modelName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelNameKey)
        UserDefaults.standard.set(url.absoluteString, forKey: endpointKey)
    }

    static func clearAPIKey() { KeychainStore.delete(account: apiKeyAccount) }
}

enum AISettingsError: LocalizedError {
    case invalidEndpoint
    case missingAPIKey
    case invalidAPIKey
    case invalidModel

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "请填写完整的 HTTPS 接口地址，包含服务要求的路径；地址中不要放账号、密钥或查询参数。"
        case .missingAPIKey: "请先填写所选服务的 API Key。密钥只会保存在这台设备。"
        case .invalidAPIKey: "API Key 中包含空格或换行，请重新粘贴完整密钥。"
        case .invalidModel: "请填写服务支持的完整模型名称，名称中不要包含空格或换行。"
        }
    }
}
