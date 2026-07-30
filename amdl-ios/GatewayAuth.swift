import Foundation
import Security

/// 发给网关的凭据，**就是 Apple 自己签的那个 identity token**。
///
/// 网关（nginx + oauth2-proxy）开了 `--skip-jwt-bearer-tokens`，会拿 Apple 的公钥
/// 直接验这个 token 的签名，再比一遍邮箱白名单。它不发自己的令牌、不存会话、
/// 也不关心调用者是谁 —— 只回答"过，还是不过"。
///
/// ## 有效期：读 token 自己说的，不要猜
///
/// 到期时刻是从这个 JWT 的 `exp` claim 解出来的，不是按经验值估的。**这一点是有
/// 来历的**：仓库里先写着「约 24 小时」，后来被"修正"成「约 10 分钟」并注明前者是
/// 观察错误——而 2026-07-30 在真机上读出来的 `exp` 是 **约 23.4 小时**，也就是说
/// 被改掉的那个才是对的，"修正"是错的，并且这个错在文档和界面文案里传播了一圈。
///
/// 所以这里不写死任何数字。Apple 想改随时可以改，而 `exp` 是这个 token 自己说的话。
///
/// 实际代价：**大约一天重新登录一次**，因为没有静默续期手段
/// （`getCredentialState` 只告诉你授权还在，不会签发新 token）。
///
/// 这比 `amdl-portal` 那一版（access 1 小时 / refresh 60 天、可连用两个月）仍然是
/// 退步，但退得远没有"每十几分钟弹一次面板"那么严重——那个说法是基于上面那个错误
/// 数字得出的。要不要为此再造一层服务端会话，是产品判断，请按一天一次来权衡。
///
nonisolated struct GatewayCredential: Codable, Sendable {
    let identityToken: String
    /// 从 token 自己的 `exp` claim 解出来的到期时刻。
    ///
    /// 解 JWT 而不是按经验值加一个偏移——见上面为什么。解不出来时按 10 分钟兜底，
    /// 那**不是**对真实寿命的估计，而是刻意悲观：宁可早问一次，也不要带着一个已经
    /// 失效的凭据出门。
    let expiresAt: Date

    /// 留 30 秒余量：请求在路上过期就是白跑一趟 401。
    var isUsable: Bool { expiresAt.timeIntervalSinceNow > 30 }

    init(identityToken: String, receivedAt: Date = Date()) {
        self.identityToken = identityToken
        // 兜底 10 分钟是刻意保守的下限，不是观测值；见 expiresAt 的注释。
        self.expiresAt = Self.expiry(ofJWT: identityToken) ?? receivedAt.addingTimeInterval(600)
    }

    /// 读 JWT payload 里的 `exp`。不校验签名 —— 校验是网关的事，这里只是想知道
    /// 什么时候该重新登录，读错了最坏也就是早问或晚问一次。
    static func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url 去掉了 padding，Data(base64Encoded:) 要求补回来。
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// 凭据的持久化。
///
/// **放在 Keychain 而不是 App Group 的 UserDefaults**：UserDefaults 的 plist 是明文、
/// 会进 iTunes/iCloud 备份、也没有"设备解锁后才可读"这种保护。这个 token 大约活一天，
/// 危害比一份 60 天的 refresh token 小，但这一天里它就是这套部署的通行证 ——
/// 而且更实际的理由是：早先版本正是把它明文存在 UserDefaults 里，那是个被专门修掉的
/// 问题，不该因为门户没了就退回去。`AppleAuthCredentialStore.purgeLegacyIdentityToken()`
/// 每次启动还在清那份旧的。
///
/// **`kSecAttrAccessGroup` 用的是 App Group id**。iOS 允许把 App Group 直接当作
/// keychain access group 用，所以主 App、分享扩展、通知扩展共享凭据**不需要新增
/// 任何 entitlement** —— 四个 target 的 `.entitlements` 里已经都有
/// `group.com.lyjw131.amdl.amdl-ios` 了。改 entitlement 要重新配 provisioning，
/// 而这里不用。
///
/// **`kSecAttrAccessibleAfterFirstUnlock`**：通知服务扩展会在锁屏状态下被唤起去下载
/// 封面，那时它得能读到凭据。`WhenUnlocked` 会让锁屏推送的附件下载静默失败。
nonisolated enum GatewayCredentialStore {
    /// 与 `DownloadsAPI.appGroupIdentifier` 相同。这里写字面量而不是引用它，是因为
    /// 分享扩展没有共享源码目录，两边都得各写一份，写死才能一眼看出必须一致。
    static let accessGroup = "group.com.lyjw131.amdl.amdl-ios"
    private static let service = "com.lyjw131.amdl.gateway"
    private static let account = "session"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    static func load() -> GatewayCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(GatewayCredential.self, from: data)
    }

    static func save(_ credential: GatewayCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
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

    /// 清掉门户时期那份 access/refresh 凭据。
    ///
    /// 它存在另一个 keychain service（`com.lyjw131.amdl.portal`）下，所以不会和上面
    /// 这份打架 —— 但里面躺着一个 60 天寿命的 refresh token，而签发它的服务已经不存在。
    /// 留着没有任何用处，删掉是对的。每次启动跑一次，代价是一次 `SecItemDelete`。
    static func purgePortalCredentials() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lyjw131.amdl.portal",
            kSecAttrAccount as String: "session",
            kSecAttrAccessGroup as String: accessGroup,
        ] as CFDictionary)
    }
}

nonisolated enum GatewayAuthError: LocalizedError {
    /// 需要重新走一次 Apple 登录：没有凭据，或者手上这份已经过期了。
    case needsSignIn
    case invalidBaseURL
    case invalidResponse
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
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

/// 错误响应的解码。
///
/// 后端用 `{"error": "..."}`，网关的 401 特意也用同一个形状（`unauthenticated`），
/// 所以一个解码器管两边。
///
/// 以前这里还要处理 problem+json，以及 `pending_approval` / `suspended` /
/// `forbidden` 三个门户专有的码 —— 那些都是门户对**账号**的判断，而账号这个概念
/// 已经没有了。
nonisolated struct GatewayErrorBody: Decodable {
    let error: String?
    let message: String?

    /// 机器可读的错误码。
    var resolvedCode: String? { error }
    /// 给人看的那句话。
    var resolvedMessage: String? { message }

    static func decode(from data: Data) -> GatewayErrorBody? {
        try? JSONDecoder().decode(GatewayErrorBody.self, from: data)
    }

    /// 把错误码映射成需要特别措辞的错误。返回 nil 表示交给调用方按普通服务端错误处理。
    ///
    /// 只剩一条了。以前这里还有 `pending_approval` 和 `suspended`，两个都是门户对
    /// 账号的判断。`unauthenticated` 留着是因为它有一个**动作**跟着 —— 重新登录 ——
    /// 而其它错误只能报出来。
    func authError(status: Int) -> GatewayAuthError? {
        if status == 401 || resolvedCode == "unauthenticated" { return .needsSignIn }
        return nil
    }
}

/// 当前凭据的持有者。
///
/// 比它取代的 `PortalSession` 简单得多。那个 actor 存在的全部理由是**刷新的单飞**
/// —— 并发的 401 如果各自去刷新，第一个换走 refresh token 之后其余的拿旧 token 去刷，
/// 门户判定为重放攻击、吊销整个令牌家族，用户被踢回登录面板。**这里没有刷新这回事**，
/// 所以没有可竞争的东西：读一份 Keychain 里的 token，过期了就是过期了。
nonisolated enum GatewaySession {
    /// 当前可用的 token；过期或没有就返回 nil，让请求裸奔去拿 401，由调用方提示登录。
    /// 这里不抛错，是因为封面图之类的请求本来就不需要凭据。
    static func bearerToken() -> String? {
        guard let credential = GatewayCredentialStore.load(), credential.isUsable else { return nil }
        return credential.identityToken
    }

    static func store(identityToken: String) {
        GatewayCredentialStore.save(GatewayCredential(identityToken: identityToken))
    }

    static func signOut() {
        GatewayCredentialStore.clear()
    }
}

/// 所有走网关的请求的唯一出口。
///
/// 它做一件 `URLSession.shared.data(for:)` 不会做的事：发之前把凭据带上。
///
/// 以前它还做第二件事 —— 收到 401 之后刷新一次再重试一次。**现在没有可刷的东西**，
/// 401 就是 401：token 过期了，只能重新弹面板。所以这里直接抛 `needsSignIn`，
/// 让界面去问，而不是静默重试一个注定失败的请求。
///
/// 封面图那类请求不必走这里：它们打的多半是 Apple CDN，401 了也就是少一张图。
enum GatewayHTTP {
    static func send(_ request: URLRequest, using session: URLSession = .shared) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let isGateway = AppleAuthCredentialStore.isGatewayHost(request.url?.host())
        if isGateway {
            request.setBearer(GatewaySession.bearerToken())
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GatewayAuthError.invalidResponse }

        if isGateway, http.statusCode == 401 {
            throw GatewayAuthError.needsSignIn
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
