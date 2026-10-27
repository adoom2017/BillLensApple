import AuthenticationServices
import CryptoKit
import Foundation
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 微软个人账户 OAuth（授权码 + PKCE），只申请只读邮件权限。
/// refresh token 只存本机钥匙串；access token 只在内存中缓存到过期前。
public enum MicrosoftAuthError: LocalizedError, Equatable {
    case notConfigured
    case cancelled
    case stateMismatch
    case missingCode
    case reauthRequired
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "当前版本未配置微软应用 ID，无法连接 Hotmail。"
        case .cancelled: "已取消连接。"
        case .stateMismatch: "授权回调校验失败，请重试。"
        case .missingCode: "微软没有返回授权码，请重试。"
        case .reauthRequired: "邮箱授权已失效，请重新连接。"
        case .server(let message): "微软登录失败：\(message)"
        }
    }
}

public struct MicrosoftOAuthConfig: Sendable, Equatable {
    public static let redirectScheme = "billumi-auth"
    public static let redirectURI = "billumi-auth://oauth"
    public static let scopes = "offline_access Mail.Read User.Read"
    static let authority = "https://login.microsoftonline.com/consumers/oauth2/v2.0"

    public let clientID: String

    public init(clientID: String) {
        self.clientID = clientID
    }

    /// 读取 Info.plist 的 `BillLensMicrosoftClientID`（由构建设置注入）；未配置时为 nil。
    public static var fromBundle: MicrosoftOAuthConfig? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BillLensMicrosoftClientID") as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return MicrosoftOAuthConfig(clientID: trimmed)
    }
}

/// PKCE 与授权请求参数。纯函数，便于单元测试。
public struct PKCERequest: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init(verifier: String = PKCERequest.randomURLSafe(bytes: 32), state: String = PKCERequest.randomURLSafe(bytes: 16)) {
        self.verifier = verifier
        self.challenge = PKCERequest.challenge(for: verifier)
        self.state = state
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public func authorizeURL(config: MicrosoftOAuthConfig) -> URL {
        var components = URLComponents(string: "\(MicrosoftOAuthConfig.authority)/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: MicrosoftOAuthConfig.redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: MicrosoftOAuthConfig.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    /// 校验回调中的 state 并取出授权码。
    public func authorizationCode(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" { throw MicrosoftAuthError.cancelled }
            throw MicrosoftAuthError.server(value("error_description") ?? error)
        }
        guard value("state") == state else { throw MicrosoftAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw MicrosoftAuthError.missingCode }
        return code
    }
}

public struct MicrosoftTokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

/// 本机钥匙串中的 Hotmail 连接信息。
public struct MicrosoftTokenStore: Sendable {
    public struct Stored: Codable, Equatable, Sendable {
        public var accountAddress: String
        public var refreshToken: String
    }

    private let item: KeychainJSONItem<Stored>

    public init(service: String = "com.shendongchun.BillLensApple.microsoft") {
        item = KeychainJSONItem(service: service, account: "hotmail")
    }

    public func load() -> Stored? { item.load() }
    public func save(_ stored: Stored) throws { try item.save(stored) }
    public func delete() { item.delete() }
}

@MainActor
public final class MicrosoftAuthService {
    public static let shared = MicrosoftAuthService()

    private let store = MicrosoftTokenStore()
    private let session = URLSession(configuration: .ephemeral)
    private var cachedAccessToken: (token: String, expiresAt: Date)?
    private var authSession: ASWebAuthenticationSession?
    private let presentation = PresentationProvider()

    public var connectedAddress: String? { store.load()?.accountAddress }

    /// 打开微软登录页完成授权，返回邮箱地址。
    public func connect(config: MicrosoftOAuthConfig) async throws -> String {
        let request = PKCERequest()
        let callback = try await authenticate(url: request.authorizeURL(config: config))
        let code = try request.authorizationCode(from: callback)
        let tokens = try await tokenRequest(config: config, parameters: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": request.verifier,
            "redirect_uri": MicrosoftOAuthConfig.redirectURI,
        ])
        guard let refreshToken = tokens.refreshToken else {
            throw MicrosoftAuthError.server("没有返回刷新令牌")
        }
        let address = try await fetchAddress(accessToken: tokens.accessToken)
        try store.save(.init(accountAddress: address, refreshToken: refreshToken))
        cache(tokens)
        AppLogger.log("mailbox.auth.connected", "ok")
        return address
    }

    /// 有效的 access token；需要时用 refresh token 换取。授权被撤销时清除钥匙串并抛出 `reauthRequired`。
    public func accessToken(config: MicrosoftOAuthConfig) async throws -> (token: String, address: String) {
        guard let stored = store.load() else { throw MicrosoftAuthError.reauthRequired }
        if let cached = cachedAccessToken, cached.expiresAt > Date.now.addingTimeInterval(300) {
            return (cached.token, stored.accountAddress)
        }
        let tokens: MicrosoftTokenResponse
        do {
            tokens = try await tokenRequest(config: config, parameters: [
                "grant_type": "refresh_token",
                "refresh_token": stored.refreshToken,
            ])
        } catch MicrosoftAuthError.reauthRequired {
            // 等待期间用户可能已断开或重新连接：只删除本次用过的那份授权。
            if store.load() == stored { disconnect() }
            throw MicrosoftAuthError.reauthRequired
        }
        // 等待网络期间用户断开或换了账户：丢弃结果，不能把轮换后的令牌写回钥匙串。
        guard store.load() == stored else { throw MicrosoftAuthError.reauthRequired }
        if let rotated = tokens.refreshToken, rotated != stored.refreshToken {
            try store.save(.init(accountAddress: stored.accountAddress, refreshToken: rotated))
        }
        cache(tokens)
        return (tokens.accessToken, stored.accountAddress)
    }

    /// 授权失效时调用，下次需要重新连接。
    public func invalidateAccessToken() {
        cachedAccessToken = nil
    }

    public func disconnect() {
        cachedAccessToken = nil
        store.delete()
    }

    private func cache(_ tokens: MicrosoftTokenResponse) {
        cachedAccessToken = (tokens.accessToken, Date.now.addingTimeInterval(TimeInterval(tokens.expiresIn)))
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: MicrosoftOAuthConfig.redirectScheme
            ) { @Sendable [weak self] callback, error in
                // 回调线程不保证是主线程：@Sendable 不继承 MainActor 隔离，状态更新切回主线程。
                Task { @MainActor in self?.authSession = nil }
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: MicrosoftAuthError.cancelled)
                } else {
                    continuation.resume(throwing: MicrosoftAuthError.server(error?.localizedDescription ?? "未知错误"))
                }
            }
            session.presentationContextProvider = presentation
            session.prefersEphemeralWebBrowserSession = true
            authSession = session
            if !session.start() {
                authSession = nil
                continuation.resume(throwing: MicrosoftAuthError.server("无法打开登录页面"))
            }
        }
    }

    private func tokenRequest(config: MicrosoftOAuthConfig, parameters: [String: String]) async throws -> MicrosoftTokenResponse {
        var request = URLRequest(url: URL(string: "\(MicrosoftOAuthConfig.authority)/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = parameters
        form["client_id"] = config.clientID
        form["scope"] = MicrosoftOAuthConfig.scopes
        request.httpBody = Self.formBody(form)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            AppLogger.log("mailbox.auth.token_error", "status=\(status) error=\(error ?? "unknown")")
            if error == "invalid_grant" || error == "interaction_required" {
                throw MicrosoftAuthError.reauthRequired
            }
            throw MicrosoftAuthError.server(error ?? "HTTP \(status)")
        }
        return try JSONDecoder().decode(MicrosoftTokenResponse.self, from: data)
    }

    private func fetchAddress(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = (object["mail"] as? String) ?? (object["userPrincipalName"] as? String),
              !address.isEmpty else {
            throw MicrosoftAuthError.server("无法读取邮箱地址")
        }
        return address
    }

    nonisolated static func formBody(_ parameters: [String: String]) -> Data {
        // RFC 3986 unreserved（仅 ASCII）；`CharacterSet.alphanumerics` 含非 ASCII 字母，不能用。
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

private final class PresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
            #endif
        }
    }
}
