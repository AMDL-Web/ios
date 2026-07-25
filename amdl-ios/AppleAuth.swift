import AuthenticationServices
import Foundation

/// 「通过 Apple 登录」拿到的凭据。
///
/// 网关（oauth2-proxy）开了 `--skip-jwt-bearer-tokens`，会直接用 Apple 的公钥
/// 校验原生登录签发的 identity token，所以 App 只要把它放进
/// `Authorization: Bearer` 就能通过认证，不需要自己实现 OAuth 重定向那一套。
/// 校验的 audience 是本 App 的 Bundle ID，网页端用的 Services ID 是另一条路。
///
/// 存在 App Group 里而不是各自的 standard defaults：分享扩展也要带着同一份
/// 凭据请求后端。实测 Apple 签发的有效期约 24 小时，过期后必须重新弹一次系统
/// 登录面板（`getCredentialState` 只告诉你授权还在，不会给新 token）。
enum AppleAuthCredentialStore {
    private static let tokenKey = "appleIdentityToken"
    private static let expiresAtKey = "appleIdentityTokenExpiresAt"
    private static let userIDKey = "appleUserID"
    private static let emailKey = "appleUserEmail"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DownloadsAPI.appGroupIdentifier)
    }

    static var userID: String? {
        get { defaults?.string(forKey: userIDKey) }
        set { defaults?.set(newValue, forKey: userIDKey) }
    }

    /// Apple 只在**首次**授权时返回邮箱，之后的 id_token 里可能没有，所以拿到
    /// 一次就留着，仅用于界面显示当前登录的是谁。
    static var email: String? {
        get { defaults?.string(forKey: emailKey) }
        set { defaults?.set(newValue, forKey: emailKey) }
    }

    static var expiresAt: Date? {
        get {
            guard let seconds = defaults?.object(forKey: expiresAtKey) as? Double else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        set {
            if let newValue {
                defaults?.set(newValue.timeIntervalSince1970, forKey: expiresAtKey)
            } else {
                defaults?.removeObject(forKey: expiresAtKey)
            }
        }
    }

    /// 未过期的 token；过期或未登录返回 nil。留 30 秒余量，避免请求在路上过期。
    static var validToken: String? {
        guard let token = defaults?.string(forKey: tokenKey), !token.isEmpty else { return nil }
        guard let expiresAt, expiresAt.timeIntervalSinceNow > 30 else { return nil }
        return token
    }

    static func store(token: String, userID: String, email: String?) {
        defaults?.set(token, forKey: tokenKey)
        self.userID = userID
        expiresAt = Self.expiration(ofJWT: token)
        // 邮箱只在首次授权时下发，后续为 nil 时不要把已有的值覆盖掉。
        if let email, !email.isEmpty {
            self.email = email
        }
    }

    static func clear() {
        defaults?.removeObject(forKey: tokenKey)
        defaults?.removeObject(forKey: expiresAtKey)
        defaults?.removeObject(forKey: userIDKey)
        defaults?.removeObject(forKey: emailKey)
    }

    /// 就地解出 JWT 的 `exp`，用来判断什么时候必须重新登录。这里只读取载荷，
    /// 不做验签——真正的校验在网关那边，App 拿它只是为了少发一次注定 401 的请求。
    static func expiration(ofJWT token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = payload["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

extension AppleAuthCredentialStore {
    /// 只给网关自己的域名带令牌。封面之类的资源可能来自 Apple CDN 或对象存储，
    /// 把身份令牌发给第三方既没必要也不安全，所以这里按 host 精确匹配。
    static func isGatewayHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let target = host.lowercased()
        return [DownloadsAPI.baseURLString, LiveActivityGatewayAPI.baseURLString]
            .compactMap { URLComponents(string: $0)?.host?.lowercased() }
            .contains(target)
    }
}

extension URLRequest {
    /// 带上网关认证头。未登录、令牌已过期、或目标不是网关域名时都不加——
    /// 请求会拿到 401，由调用方提示重新登录，而不是在这里静默失败。
    mutating func authorizeWithApple() {
        guard let token = AppleAuthCredentialStore.validToken,
              AppleAuthCredentialStore.isGatewayHost(url?.host())
        else { return }
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    init(authorizedURL url: URL) {
        self.init(url: url)
        authorizeWithApple()
    }
}

extension URLSession {
    /// WebSocket 也要过网关认证，所以不能用 `webSocketTask(with: URL)`——
    /// 那个重载没法带自定义头。
    func authorizedWebSocketTask(with url: URL) -> URLSessionWebSocketTask {
        webSocketTask(with: URLRequest(authorizedURL: url))
    }
}

enum AppleAuthError: LocalizedError {
    case missingIdentityToken
    case canceled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken:
            "Apple 没有返回身份令牌，请重试。"
        case .canceled:
            "已取消登录。"
        case .failed(let message):
            message
        }
    }
}

/// 登录状态，供界面观察。
///
/// identity token 实测有效期约 24 小时，没有任何静默续期手段：
/// `getCredentialState` 只告诉你授权还在，不会给新 token，oauth2-proxy 的
/// Bearer 路径也不下发会话 cookie。过期后必须重新弹一次系统登录面板。
@MainActor
@Observable
final class AppleAuthStore {
    static let shared = AppleAuthStore()

    private(set) var userID: String?
    private(set) var email: String?
    private(set) var expiresAt: Date?
    private(set) var isSigningIn = false

    private var controllerBox: SignInController?

    private init() {
        userID = AppleAuthCredentialStore.userID
        email = AppleAuthCredentialStore.email
        expiresAt = AppleAuthCredentialStore.expiresAt
    }

    /// 授权还在（登录过且没有登出），但令牌可能已经过期。
    var isSignedIn: Bool { userID != nil }

    /// 手上有可用令牌，请求能直接带上。
    var hasValidToken: Bool { AppleAuthCredentialStore.validToken != nil }

    func signIn() async throws {
        isSigningIn = true
        defer { isSigningIn = false }

        let controller = SignInController()
        controllerBox = controller
        defer { controllerBox = nil }

        let credential = try await controller.perform()
        guard let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            throw AppleAuthError.missingIdentityToken
        }
        AppleAuthCredentialStore.store(
            token: token,
            userID: credential.user,
            email: credential.email
        )
        userID = AppleAuthCredentialStore.userID
        email = AppleAuthCredentialStore.email
        expiresAt = AppleAuthCredentialStore.expiresAt
    }

    func signOut() {
        AppleAuthCredentialStore.clear()
        userID = nil
        email = nil
        expiresAt = nil
    }

    /// 令牌过期后刷新界面用：重新读一遍存储里的过期时间。
    func refreshFromStore() {
        userID = AppleAuthCredentialStore.userID
        email = AppleAuthCredentialStore.email
        expiresAt = AppleAuthCredentialStore.expiresAt
    }
}

/// 把 `ASAuthorizationController` 的 delegate 回调桥接成 async。
/// 控制器只用一次，回调后即失效。
@MainActor
private final class SignInController: NSObject,
                                      ASAuthorizationControllerDelegate,
                                      ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    func perform() async throws -> ASAuthorizationAppleIDCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        // 邮箱是网关白名单的匹配依据，必须要；姓名只在首次授权时下发，留着备用。
        request.requestedScopes = [.email, .fullName]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AppleAuthError.missingIdentityToken)
            continuation = nil
            return
        }
        continuation?.resume(returning: credential)
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let resolved: Error = if let authError = error as? ASAuthorizationError,
                                 authError.code == .canceled {
            AppleAuthError.canceled
        } else {
            AppleAuthError.failed(error.localizedDescription)
        }
        continuation?.resume(throwing: resolved)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
