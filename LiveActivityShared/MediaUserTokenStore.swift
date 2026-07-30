import Foundation
import Security

/// 主 App 从 MusicKit 取到的 media user token，存一份给扩展读。
///
/// **为什么要存**：`MusicDataRequest.tokenProvider` 只在主 App 进程里问得到。
/// 分享扩展有自己的 bundle id、Info.plist 里没有 `NSAppleMusicUsageDescription`、
/// 也没有能弹授权面板的宿主——它问不到 MusicKit，所以令牌只能由主 App 存下来。
/// 这也是 `AGENTS.md`「不要拿 MusicKit 去补任务里的空缺」在这里的具体形态：
/// 缺的不是数据，是一个能取到数据的进程。
///
/// **为什么存钥匙串而不是 App Group 的 UserDefaults**：和 `GatewayCredentialStore`
/// 同一个理由——这是一份能代表用户 Apple Music 账号的凭据，UserDefaults 的 plist
/// 是明文、会进备份、也没有「解锁之后才可读」这种保护。
///
/// **不需要新增任何 entitlement**：`kSecAttrAccessGroup` 直接用 App Group id，
/// iOS 允许这么用，而四个 target 的 `.entitlements` 里都已经有
/// `group.com.lyjw131.amdl.amdl-ios`。分享扩展读门户会话
/// （`ShareViewController.portalBearerToken()`）走的就是这条路，而且线上一直在用：
/// 分享出去的任务能被门户接受，说明那次钥匙串读取是成功的。
///
/// `kSecAttrAccessibleAfterFirstUnlock` 与门户凭据保持一致。分享面板本身要求设备
/// 已解锁，但通知服务扩展会在锁屏时被唤起，将来若要在那里读同一份令牌，
/// `WhenUnlocked` 会让它静默失败。
nonisolated struct SharedMediaUserToken: Codable, Sendable, Equatable {
    let value: String
    /// 主 App 上一次把这份副本写进钥匙串的时刻。
    let updatedAt: Date

    /// 超过这个时长就当它已经不可信。
    ///
    /// 主 App **每次进前台**都会刷新这份副本（`AppDelegate.applicationDidBecomeActive`），
    /// 所以「副本很旧」等价于「主 App 很久没被打开过」，那时候令牌多半已经失效。
    /// 阈值取得很宽是故意的：拦下一次本来能成功的提交，比放过一次注定失败的提交
    /// 更糟，所以只在「三个月没开过 App」这种一眼就该去开一次 App 的情况下才判旧。
    static let staleAfter: TimeInterval = 90 * 24 * 60 * 60

    /// 纯函数，便于测试：不读系统时钟。
    func isFresh(now: Date = Date()) -> Bool {
        !value.isEmpty && now.timeIntervalSince(updatedAt) < Self.staleAfter
    }
}

nonisolated enum MediaUserTokenStore {
    /// 与 `GatewayCredentialStore.accessGroup` 是同一个组。这里引用
    /// `BackendEndpoint.appGroupIdentifier`，因为这个文件本身就在
    /// `LiveActivityShared/` 里，两边看得见同一个常量。
    static let accessGroup = BackendEndpoint.appGroupIdentifier
    /// 和门户会话分开存：它们的生命周期、失效原因、清除时机都不一样，
    /// 退出门户登录不该顺手把 Apple Music 的令牌也删了。
    private static let service = "com.lyjw131.amdl.musickit"
    private static let account = "media-user-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    static func load() -> SharedMediaUserToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(SharedMediaUserToken.self, from: data),
              !stored.value.isEmpty
        else { return nil }
        return stored
    }

    /// 存一份新的副本。空串等于「没有令牌」，直接清掉——留着一个空值只会让读的
    /// 那一侧多一个「有但是空」的分支。
    static func save(_ token: String, updatedAt: Date = Date()) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }
        guard let data = try? JSONEncoder().encode(
            SharedMediaUserToken(value: trimmed, updatedAt: updatedAt)
        ) else { return }

        // 先删后写，同 `GatewayCredentialStore.save`：`SecItemUpdate` 在条目不存在时
        // 返回 errSecItemNotFound，分两条路径只是多一个分支。
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
