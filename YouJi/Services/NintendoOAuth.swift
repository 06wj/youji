import CryptoKit
import Foundation
import Security

struct NintendoOAuthSession: Sendable {
    static let clientID = "5c38e31cd085304b"
    static let redirectURI = "npf\(clientID)://auth"

    let state: String
    let verifier: String
    let authorizationURL: URL

    static func make() -> NintendoOAuthSession {
        let state = randomBase64URL(byteCount: 36)
        let verifier = randomBase64URL(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let scopes = ["openid", "user", "user.mii", "user.email", "user.links[].id"].joined(separator: " ")
        var components = URLComponents(string: "https://accounts.nintendo.com/connect/1.0.0/authorize")!
        components.queryItems = [
            .init(name: "state", value: state),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "client_id", value: clientID),
            .init(name: "scope", value: scopes),
            .init(name: "response_type", value: "session_token_code"),
            .init(name: "session_token_code_challenge", value: challenge),
            .init(name: "session_token_code_challenge_method", value: "S256"),
            .init(name: "theme", value: "login_form"),
        ]
        return .init(state: state, verifier: verifier, authorizationURL: components.url!)
    }

    func parseCallback(_ url: URL) throws -> String {
        guard url.scheme == "npf\(Self.clientID)" else { throw NintendoAuthError.invalidCallback }
        let fragment = URLComponents(string: "https://callback.invalid/?\(url.fragment ?? "")")
        let values = Dictionary(uniqueKeysWithValues: (fragment?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        guard values["state"] == state else { throw NintendoAuthError.stateMismatch }
        if let message = values["error_description"] ?? values["error"] { throw NintendoAuthError.server(message) }
        guard let code = values["session_token_code"], !code.isEmpty else { throw NintendoAuthError.missingCode }
        return code
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum NintendoAuthError: LocalizedError {
    case invalidCallback, stateMismatch, missingCode, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidCallback: "登录回跳地址无效"
        case .stateMismatch: "登录状态校验失败，请重试"
        case .missingCode: "Nintendo 未返回授权码"
        case .server(let message): message
        }
    }
}
