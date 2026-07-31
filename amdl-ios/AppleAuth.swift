import AuthenticationServices
import Foundation

/// 「通过 Apple 登录」的**身份**部分：这个设备上登录的是谁。
///
/// 认证凭据本身在 `GatewayAuth.swift`。凭据就是 Apple 的 identity token 本身，
/// 直接当 `Authorization: Bearer` 发给网关的 oauth2-proxy（它开了
/// `--skip-jwt-bearer-tokens`，会用 Apple 公钥自己验签）。
///
/// 中间有一版不是这样：`amdl-portal` 用 identity token 换一对自己的
/// access/refresh，为的是绕开"identity token 无法静默续期"（当时以为它只活十分钟，
/// 实际约一天，见 `GatewayCredential`）。
/// 整套系统改回单用户设计时门户被删了，这条路也就跟着回到了直发 —— 连带那个
/// 每隔十几分钟弹一次面板的代价。取舍的完整说明在 `GatewayCredential` 的注释里。
///
/// 留在 App Group 的 UserDefaults 里的只有用户 id 和邮箱——都是给界面显示"当前登录
/// 的是谁"用的，不是凭据。**真正的凭据在 Keychain**（`GatewayCredentialStore`）。
enum AppleAuthCredentialStore {
    private static let userIDKey = "appleUserID"
    private static let emailKey = "appleUserEmail"
    /// 旧版本把 Apple identity token 明文存在 App Group 的 UserDefaults 里。它现在
    /// 没有用处，但**留着就是一份长期躺在明文 plist 里的凭据**，所以升级时主动清掉。
    private static let legacyTokenKey = "appleIdentityToken"
    private static let legacyExpiresAtKey = "appleIdentityTokenExpiresAt"

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

    /// 凭据的到期时刻，供界面显示。**这次它是真的**：没有续期，过了就得重新登录，
    /// 所以界面拿它倒计时是准的。门户时期它只是个装饰 —— 那时快过期会自动续。
    static var expiresAt: Date? {
        GatewayCredentialStore.load()?.expiresAt
    }

    /// 手上有没有一份**还能用**的凭据。
    static var hasUsableCredential: Bool {
        GatewayCredentialStore.load()?.isUsable ?? false
    }

    static func store(userID: String, email: String?) {
        self.userID = userID
        // 邮箱只在首次授权时下发，后续为 nil 时不要把已有的值覆盖掉。
        if let email, !email.isEmpty {
            self.email = email
        }
    }

    static func clear() {
        defaults?.removeObject(forKey: userIDKey)
        defaults?.removeObject(forKey: emailKey)
        purgeLegacyIdentityToken()
    }

    /// 启动时跑一次的清理：明文 plist 里的旧 token，以及门户时期那份 60 天的
    /// refresh token。两者签发方都已经不存在了。
    static func purgeRetiredCredentials() {
        purgeLegacyIdentityToken()
        GatewayCredentialStore.purgePortalCredentials()
    }

    /// 清掉旧版本留在明文 plist 里的 Apple identity token。
    ///
    /// 每次启动都跑一次，代价是两次 `removeObject`。它早就失效了，
    /// 所以这不是功能问题；但一份用户凭据留在会进备份的明文文件里，删掉才对。
    static func purgeLegacyIdentityToken() {
        defaults?.removeObject(forKey: legacyTokenKey)
        defaults?.removeObject(forKey: legacyExpiresAtKey)
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
    /// 带上网关的认证头。目标不是网关域名时什么都不加。
    ///
    /// 门户时期这里还有个"同步 / 异步"的区分：异步版本要能刷新 token，同步版本
    /// 只读现成的。**没有刷新之后两者是同一件事**，所以只剩这一个。
    mutating func authorizeForGateway() {
        guard AppleAuthCredentialStore.isGatewayHost(url?.host()) else { return }
        setBearer(GatewaySession.bearerToken())
    }

    init(authorizedURL url: URL) {
        self.init(url: url)
        authorizeForGateway()
    }
}

extension URLSession {
    /// WebSocket 也要过网关认证，所以不能用 `webSocketTask(with: URL)`——
    /// 那个重载没法带自定义头。
    ///
    /// 握手头在建任务的那一刻就定死了，之后没有补救机会——`URLSessionWebSocketTask`
    /// 只会失败，调用方看到的是一次断线，然后重连、再断线。凭据过期时这条路径就是
    /// 这个样子，而且**没有办法在这一层修**：唯一能给出新 token 的是系统登录面板。
    /// 所以断线重连若持续失败，界面要引导用户重新登录，而不是继续重连。
    func authorizedWebSocketTask(with url: URL) -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        request.authorizeForGateway()
        return webSocketTask(with: request)
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
/// 登录是**一步**：让系统弹面板，把拿到的 identity token 存进 Keychain，完事。
/// 那个 token 本身就是发给网关的凭据。
///
/// 中间有一版是两步 —— 第二步拿 identity token 去 `POST /api/gw/auth/apple/native`
/// 换门户的 access/refresh。那一步是为了绕开 identity token 无法续期这件事；
/// 门户删掉之后它没有了，代价见 `GatewayCredential`。
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
        // 明文 plist 里的旧 token，以及门户那份 60 天的 refresh token。
        AppleAuthCredentialStore.purgeRetiredCredentials()
    }

    /// 登录过且手上的凭据还没过期。
    ///
    /// **和门户时期不是一个意思**：那时凭据过期只要 refresh 还在就能续，所以
    /// `isSignedIn` 只看"登录过没有"。现在过期就是真的要重新登录了，所以这里必须
    /// 把有效性一起算进去 —— 否则界面会一直显示已登录，而每个请求都是 401。
    var isSignedIn: Bool { userID != nil && AppleAuthCredentialStore.hasUsableCredential }

    /// 手上有一份还能用的凭据。
    var hasValidToken: Bool { AppleAuthCredentialStore.hasUsableCredential }

    func signIn() async throws {
        isSigningIn = true
        defer { isSigningIn = false }

        guard let anchor = SignInController.frontmostWindow() else {
            throw AppleAuthError.failed("找不到可用于展示登录面板的窗口，请重试。")
        }

        let controller = SignInController(anchor: anchor)
        controllerBox = controller
        defer { controllerBox = nil }

        let credential = try await controller.perform()
        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8)
        else {
            throw AppleAuthError.missingIdentityToken
        }

        // credential.authorizationCode 不再发给任何人：它是用来在服务端跟 Apple
        // 换 refresh token 的，而现在没有服务端会话可换。
        GatewaySession.store(identityToken: identityToken)

        AppleAuthCredentialStore.store(userID: credential.user, email: credential.email)
        userID = AppleAuthCredentialStore.userID
        email = AppleAuthCredentialStore.email
        expiresAt = AppleAuthCredentialStore.expiresAt
    }

    func signOut() {
        AppleAuthCredentialStore.clear()
        GatewaySession.signOut()
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
    private let anchor: ASPresentationAnchor

    /// 前台 scene 的 key window。iOS 26 起 `UIWindow()` 和 `UIWindow(frame:)` 都已
    /// 废弃——窗口必须绑定 scene——而真没有窗口时系统面板本来也无处可弹。所以这里
    /// 返回可选，让调用方把它当成一次失败的登录，而不是造一个游离窗口、让面板无声
    /// 地不出现。
    fileprivate static func frontmostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foreground = scenes.first { $0.activationState == .foregroundActive }
        return (foreground ?? scenes.first)?.keyWindow
    }

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
        super.init()
    }

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
        anchor
    }
}
