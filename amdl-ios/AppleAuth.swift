import AuthenticationServices
import Foundation

/// 「通过 Apple 登录」的**身份**部分：这个设备上登录的是谁。
///
/// 认证凭据本身不在这里了。以前 App 把 Apple 的 identity token 直接当
/// `Authorization: Bearer` 发给 oauth2-proxy（它开了 `--skip-jwt-bearer-tokens`，
/// 会用 Apple 公钥自己验签）。换成 `amdl-portal` 之后不是这样：identity token 只
/// 用来**换一次**门户自己的会话，之后所有请求带的是门户签发的 access token，见
/// `PortalAuth.swift`。
///
/// 这不是重构，是修一个体验缺陷：Apple 的 identity token 实测只活约 10 分钟，
/// 而且没有静默续期手段，所以旧方案下用户每隔十几分钟就得重新弹一次系统登录面板。
/// 门户的 refresh token 是 60 天，App 因此可以连着用两个月不弹面板。
///
/// 留在 App Group 的 UserDefaults 里的只有用户 id 和邮箱——都是给界面显示"当前登录
/// 的是谁"用的，不是凭据。**真正的凭据在 Keychain**（`PortalCredentialStore`）。
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

    /// 门户会话的到期时刻，仅供界面显示。真正决定请求带不带凭据的是
    /// `PortalSession`，它在快过期时会自己续，所以这里过期了也不代表要重新登录。
    static var expiresAt: Date? {
        PortalCredentialStore.load()?.accessTokenExpiresAt
    }

    /// 手上有没有一份**能续**的门户会话。access token 过期无所谓——refresh 还在就
    /// 能续，而 refresh 有 60 天。
    static var hasPortalSession: Bool { PortalCredentialStore.load() != nil }

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

    /// 清掉旧版本留在明文 plist 里的 Apple identity token。
    ///
    /// 每次启动都跑一次，代价是两次 `removeObject`。它早就失效了（10 分钟寿命），
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
    /// 带上门户的认证头，**同步**版本：只读 Keychain 里现成的 access token，
    /// 不做刷新。目标不是门户域名时什么都不加。
    ///
    /// 需要刷新和 401 重试的请求走 `PortalHTTP.send`。这个同步版本留给两类调用方：
    /// 封面图这种"401 了也就是少一张图"的请求，以及 WebSocket——
    /// `URLSessionWebSocketTask` 的握手头必须在创建任务时就定下来，没有异步的余地。
    mutating func authorizeWithPortal() {
        guard AppleAuthCredentialStore.isGatewayHost(url?.host()) else { return }
        setBearer(PortalCredentialStore.load()?.accessToken)
    }

    init(authorizedURL url: URL) {
        self.init(url: url)
        authorizeWithPortal()
    }
}

extension URLSession {
    /// WebSocket 也要过门户认证，所以不能用 `webSocketTask(with: URL)`——
    /// 那个重载没法带自定义头。
    ///
    /// **async 的原因**：握手头在建任务的那一刻就定死了，之后没有"401 了再刷一次
    /// 重试"的机会——`URLSessionWebSocketTask` 只会失败，调用方看到的是一次断线，
    /// 然后重连、再断线。所以刷新必须发生在握手**之前**。App 在后台待过一小时
    /// 之后回到前台的第一次重连就是这条路径。
    func authorizedWebSocketTask(with url: URL) async -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        if AppleAuthCredentialStore.isGatewayHost(url.host()) {
            request.setBearer(await PortalSession.shared.accessToken())
        }
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
/// 登录是**两步**，而且第二步才是重点：先让系统弹面板拿 Apple 的 identity token，
/// 再拿它去 `POST /api/gw/auth/apple/native` 换门户的会话。identity token 只活约
/// 10 分钟且无法静默续期，门户的 refresh token 是 60 天并且每次刷新都轮换——
/// 换取这一步就是 App 能连着用两个月不弹面板的全部原因。
@MainActor
@Observable
final class AppleAuthStore {
    static let shared = AppleAuthStore()

    private(set) var userID: String?
    private(set) var email: String?
    private(set) var expiresAt: Date?
    private(set) var isSigningIn = false
    /// 账号还没被管理员批准。**每个新用户第一次登录看到的都是这个状态**，界面必须
    /// 说人话而不是弹一个 403。登录本身是成功的：门户给 pending 账号也发凭据，
    /// 好让 App 能调 `/api/gw/me` 问出自己是 pending（DESIGN.md §6.2）。
    private(set) var isPendingApproval = false

    private var controllerBox: SignInController?

    private init() {
        userID = AppleAuthCredentialStore.userID
        email = AppleAuthCredentialStore.email
        expiresAt = AppleAuthCredentialStore.expiresAt
        // 顺手清掉旧版本明文存下的 Apple identity token。
        AppleAuthCredentialStore.purgeLegacyIdentityToken()
    }

    /// 登录过且没有登出。access token 可能已过期，但 refresh 还在就不用管。
    var isSignedIn: Bool { userID != nil && AppleAuthCredentialStore.hasPortalSession }

    /// 手上有一份门户会话。
    var hasValidToken: Bool { AppleAuthCredentialStore.hasPortalSession }

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

        // authorizationCode 门户目前收下但不用（DESIGN.md §6.2），照发即可——
        // 将来门户要用它去 Apple 查询 Apple ID 是否被撤销时，不需要 App 再发版。
        let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        _ = try await PortalSession.shared.exchange(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            fullName: credential.fullName?.formatted()
        )

        AppleAuthCredentialStore.store(userID: credential.user, email: credential.email)
        userID = AppleAuthCredentialStore.userID
        email = AppleAuthCredentialStore.email
        expiresAt = AppleAuthCredentialStore.expiresAt
        await refreshAccountStatus()
    }

    func signOut() {
        AppleAuthCredentialStore.clear()
        Task { await PortalSession.shared.signOut() }
        userID = nil
        email = nil
        expiresAt = nil
        isPendingApproval = false
    }

    /// 问一次门户"我现在是什么状态"。
    ///
    /// `GET /api/gw/me` 是 pending 账号**唯一**能调通的接口，所以它是 App 判断
    /// "登录成功但还不能用"的唯一途径——别的接口一律 403，从状态码上分不出
    /// "没批准"和"权限不够"。
    func refreshAccountStatus() async {
        guard let status = await PortalAccount.fetchStatus() else { return }
        isPendingApproval = status == "pending"
    }

    /// 令牌过期后刷新界面用：重新读一遍存储里的过期时间。
    func refreshFromStore() {
        userID = AppleAuthCredentialStore.userID
        email = AppleAuthCredentialStore.email
        expiresAt = AppleAuthCredentialStore.expiresAt
    }

    /// 请求侧发现账号还没批准时回调，把状态推给界面。
    func markPendingApproval() {
        isPendingApproval = true
    }
}

/// `GET /api/gw/me` 的最小解码：这一版只需要账号状态。
enum PortalAccount {
    static func fetchStatus() async -> String? {
        guard !DownloadsAPI.baseURLString.isEmpty,
              var components = URLComponents(string: DownloadsAPI.baseURLString)
        else { return nil }
        components.path = "/api/gw/me"
        guard let url = components.url else { return nil }

        struct Response: Decodable {
            struct User: Decodable { let status: String }
            let user: User
        }
        guard let (data, http) = try? await PortalHTTP.send(URLRequest(url: url)),
              http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        return decoded.user.status
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
