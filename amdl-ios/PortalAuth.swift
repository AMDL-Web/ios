import Foundation
import Security

/// 门户（`amdl-portal`）签发的会话凭据。
///
/// 为什么需要这一层：Apple 原生登录给的 identity token **实测只活约 10 分钟**
/// （早先注释写的 24 小时是观察错误，见 §6.2），而且没有任何静默续期手段——
/// `getCredentialState` 只告诉你授权还在，不会给新 token。以前 App 直接把它当
/// Bearer 发给 oauth2-proxy，代价就是每隔十几分钟必须重新弹一次系统登录面板。
///
/// 现在换成：identity token 只用一次，换成门户自己的 access/refresh 对，
/// access 1 小时、refresh 60 天且每次刷新都轮换。App 因此可以连着用两个月不弹面板。
nonisolated struct PortalCredentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    /// access token 的到期时刻。由 `expires_in` 加上收到响应的时间算出——服务端
    /// 只给相对秒数，本地时钟偏移会让绝对时间不准，但刷新是由 401 兜底的，
    /// 这个时间只用来**提前**刷新，早一点晚一点都不会造成故障。
    let accessTokenExpiresAt: Date

    /// 留 60 秒余量：请求在路上过期会白跑一趟 401。
    var isAccessTokenUsable: Bool { accessTokenExpiresAt.timeIntervalSinceNow > 60 }
}

/// 门户凭据的持久化。
///
/// **放在 Keychain 而不是 App Group 的 UserDefaults**：refresh token 有 60 天寿命，
/// 拿到它等于拿到这个账号两个月的访问权，而 UserDefaults 的 plist 是明文、会进
/// iTunes/iCloud 备份、也没有"设备解锁后才可读"这种保护。旧的 identity token 存在
/// UserDefaults 里问题还小一些——它十分钟就废了。
///
/// **`kSecAttrAccessGroup` 用的是 App Group id**。iOS 允许把 App Group 直接当作
/// keychain access group 用，所以主 App、分享扩展、通知扩展共享凭据**不需要新增
/// 任何 entitlement**——四个 target 的 `.entitlements` 里已经都有
/// `group.com.lyjw131.amdl.amdl-ios` 了。这一点很重要：改 entitlement 要重新配
/// provisioning，而这里不用。
///
/// **`kSecAttrAccessibleAfterFirstUnlock`**：通知服务扩展会在锁屏状态下被唤起去下载
/// 封面，那时它得能读到凭据。`WhenUnlocked` 会让锁屏推送的附件下载静默失败。
nonisolated enum PortalCredentialStore {
    /// 与 `DownloadsAPI.appGroupIdentifier` 相同。这里写字面量而不是引用它，是因为
    /// 分享扩展没有共享源码目录，两边都得各写一份，写死才能一眼看出必须一致。
    static let accessGroup = "group.com.lyjw131.amdl.amdl-ios"
    private static let service = "com.lyjw131.amdl.portal"
    private static let account = "session"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    static func load() -> PortalCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(PortalCredentials.self, from: data)
    }

    static func save(_ credentials: PortalCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        // 先删后写。SecItemUpdate 在条目不存在时返回 errSecItemNotFound，两条路径
        // 分开写只会多一个分支，收益是零。
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// 门户返回的错误码。三个 API 面共用同一张表（DESIGN.md §6.3）：
/// `/api/gw/*` 放在 problem+json 的 `code` 里，`/api/v1/*` 放在 `{"error": ...}` 里。
nonisolated enum PortalErrorCode {
    static let unauthenticated = "unauthenticated"
    static let pendingApproval = "pending_approval"
    static let suspended = "suspended"
    static let forbidden = "forbidden"
}

nonisolated enum PortalAuthError: LocalizedError {
    /// 账号已登录但还没被管理员批准。**每个新用户第一次进来看到的都是这个**，
    /// 所以它必须有一句人话，而不是"服务器错误 (403)"。
    case pendingApproval
    case suspended
    /// 需要重新走一次 Apple 登录：没有凭据，或者 refresh token 也失效了。
    case needsSignIn
    case invalidBaseURL
    case invalidResponse
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .pendingApproval:
            "账号正在等待管理员批准。批准之后不用重新登录，直接就能用。"
        case .suspended:
            "这个账号已被停用，请联系管理员。"
        case .needsSignIn:
            "登录已过期，请重新「通过 Apple 登录」。"
        case .invalidBaseURL:
            "服务器地址无效，请到「配置」页检查"
        case .invalidResponse:
            "服务器返回了无法解析的数据"
        case let .server(status, message):
            message ?? "服务器错误 (\(status))"
        }
    }
}

/// 门户错误响应的两种形状。`/api/gw/*` 是 RFC 9457 的 problem+json，`/api/v1/*`
/// 是后端原本的 `{"error":...}`——两边的**机器可读值是同一张表**，所以解码成一个
/// 类型，谁有值用谁的。
nonisolated struct PortalErrorBody: Decodable {
    let code: String?
    let error: String?
    let detail: String?
    let message: String?
    let title: String?

    /// 机器可读的错误码，两种形状取其一。
    var resolvedCode: String? { code ?? error }
    /// 给人看的那句话。
    var resolvedMessage: String? { detail ?? message ?? title }

    static func decode(from data: Data) -> PortalErrorBody? {
        try? JSONDecoder().decode(PortalErrorBody.self, from: data)
    }

    /// 把错误码映射成有意义的错误。返回 nil 表示这不是一个需要特别措辞的状态。
    func authError(status: Int) -> PortalAuthError? {
        switch resolvedCode {
        case PortalErrorCode.pendingApproval: .pendingApproval
        case PortalErrorCode.suspended: .suspended
        case PortalErrorCode.unauthenticated: .needsSignIn
        default: nil
        }
    }
}

/// 令牌的换取与刷新。
///
/// 单独做成 actor 是为了**刷新的单飞**：App 启动时会并发发好几个请求（列表、
/// 配置、设备注册），access token 过期时它们会同时拿到 401。如果每个都各自去刷新，
/// 第一个换走 refresh token 之后，其余的拿着已经轮换掉的旧 token 去刷——门户把
/// 这判定为重放攻击，会**吊销整个令牌家族**（DESIGN.md §6.2），用户被踢回登录面板。
/// 所以刷新必须全局只有一个在飞，其余的等它。
actor PortalSession {
    static let shared = PortalSession()

    private var refreshTask: Task<PortalCredentials, Error>?

    /// 用 Apple 的 identity token 换门户的会话。只在用户刚点完系统登录面板时调用一次。
    func exchange(identityToken: String, authorizationCode: String?, fullName: String?) async throws -> PortalCredentials {
        struct Body: Encodable {
            let identityToken: String
            let authorizationCode: String?
            let fullName: String?

            enum CodingKeys: String, CodingKey {
                case identityToken = "identity_token"
                case authorizationCode = "authorization_code"
                case fullName = "full_name"
            }
        }
        let credentials = try await post(
            path: "/api/gw/auth/apple/native",
            body: Body(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                fullName: fullName
            )
        )
        PortalCredentialStore.save(credentials)
        return credentials
    }

    /// 当前可用的 access token；快到期就先刷新。没有凭据时返回 nil，让请求裸奔去拿
    /// 401，由调用方提示登录——这里不抛错，是因为封面图之类的请求本来就不需要凭据。
    func accessToken() async -> String? {
        guard let credentials = PortalCredentialStore.load() else { return nil }
        if credentials.isAccessTokenUsable {
            return credentials.accessToken
        }
        return try? await refresh(using: credentials.refreshToken).accessToken
    }

    /// 收到 401 之后刷新一次。返回新的 access token，或者 nil 表示真的得重新登录了。
    func refreshAfterUnauthorized(usedToken: String?) async -> String? {
        // 别人可能已经刷过了：如果存着的 token 和刚才用的那个不是同一个，直接用新的，
        // 不要再消耗一次 refresh。并发 401 的常态就是这一条分支。
        if let current = PortalCredentialStore.load(), current.isAccessTokenUsable,
           current.accessToken != usedToken {
            return current.accessToken
        }
        guard let refreshToken = PortalCredentialStore.load()?.refreshToken else { return nil }
        return try? await refresh(using: refreshToken).accessToken
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        PortalCredentialStore.clear()
    }

    /// 单飞的刷新。同一时刻只有一个 refresh 请求在飞，其余 await 同一个 Task。
    private func refresh(using refreshToken: String) async throws -> PortalCredentials {
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        let task = Task<PortalCredentials, Error> { [weak self] in
            struct Body: Encodable {
                let refreshToken: String
                enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
            }
            guard let self else { throw PortalAuthError.needsSignIn }
            do {
                let credentials = try await self.post(
                    path: "/api/gw/auth/refresh",
                    body: Body(refreshToken: refreshToken)
                )
                PortalCredentialStore.save(credentials)
                return credentials
            } catch PortalAuthError.needsSignIn {
                // refresh token 也不认了（过期、被吊销、或者重放检测触发）。
                // 清掉，让界面回到"请登录"，而不是留着一份注定 401 的凭据反复重试。
                PortalCredentialStore.clear()
                throw PortalAuthError.needsSignIn
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// 认证端点的 POST。这两个端点**本身不带 Authorization**——它们就是用来拿凭据的。
    private func post<Body: Encodable>(path: String, body: Body) async throws -> PortalCredentials {
        // baseURLString 存在 App Group 的 UserDefaults 里，属于主 actor 的状态，
        // 所以这里显式跳一次；剩下的网络和 Keychain 工作留在本 actor 上。
        let baseURLString = await MainActor.run { DownloadsAPI.baseURLString }
        guard !baseURLString.isEmpty,
              var components = URLComponents(string: baseURLString)
        else { throw PortalAuthError.invalidBaseURL }
        components.path = path
        guard let url = components.url else { throw PortalAuthError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PortalAuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = PortalErrorBody.decode(from: data)
            if http.statusCode == 401 { throw PortalAuthError.needsSignIn }
            if let mapped = body?.authError(status: http.statusCode) { throw mapped }
            throw PortalAuthError.server(status: http.statusCode, message: body?.resolvedMessage)
        }

        guard let pair = try? JSONDecoder().decode(PortalTokenPair.self, from: data) else {
            throw PortalAuthError.invalidResponse
        }
        return PortalCredentials(
            accessToken: pair.accessToken,
            refreshToken: pair.refreshToken,
            accessTokenExpiresAt: Date().addingTimeInterval(TimeInterval(pair.expiresIn))
        )
    }
}

/// 所有走门户的请求的唯一出口。
///
/// 它做两件 `URLSession.shared.data(for:)` 不会做的事：
///
/// 1. **发之前**确保 access token 是新鲜的（快过期就先刷）。
/// 2. **收到 401 之后**刷新一次并重试一次。只重试一次——如果刷新过的 token 还是
///    401，那就是真的需要重新登录了，再试下去只会把 refresh 家族折腾没。
///
/// 封面图那类请求不必走这里：它们打的多半是 Apple CDN，401 了也就是少一张图。
enum PortalHTTP {
    static func send(_ request: URLRequest, using session: URLSession = .shared) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let isPortal = AppleAuthCredentialStore.isGatewayHost(request.url?.host())
        var usedToken: String?
        if isPortal {
            usedToken = await PortalSession.shared.accessToken()
            request.setBearer(usedToken)
        }

        var (data, response) = try await session.data(for: request)
        guard var http = response as? HTTPURLResponse else { throw PortalAuthError.invalidResponse }

        if isPortal, http.statusCode == 401 {
            guard let refreshed = await PortalSession.shared.refreshAfterUnauthorized(usedToken: usedToken) else {
                throw PortalAuthError.needsSignIn
            }
            request.setBearer(refreshed)
            (data, response) = try await session.data(for: request)
            guard let retried = response as? HTTPURLResponse else { throw PortalAuthError.invalidResponse }
            http = retried
            if http.statusCode == 401 { throw PortalAuthError.needsSignIn }
        }

        // 403 的两个原因都需要一句人话，而且都不是"重试就好"：pending 要等管理员，
        // suspended 要找管理员。放在这里而不是每个调用方各判一次。
        if http.statusCode == 403,
           let mapped = PortalErrorBody.decode(from: data)?.authError(status: http.statusCode) {
            throw mapped
        }
        return (data, http)
    }
}

nonisolated extension URLRequest {
    mutating func setBearer(_ token: String?) {
        guard let token, !token.isEmpty else {
            setValue(nil, forHTTPHeaderField: "Authorization")
            return
        }
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

/// `POST /api/gw/auth/apple/native` 和 `/api/gw/auth/refresh` 的响应体
/// （门户的 `auth.TokenPair`，DESIGN.md §6.2）。
nonisolated struct PortalTokenPair: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
