import Foundation

/// 门户地址的唯一事实来源。
///
/// `amdl-portal` 上线后，一个域名兜住了全部三条链路：`/api/v1/*`（后端镜像）、
/// `/api/gw/*`（门户自己的接口）、`/apns/*`（剥掉前缀之后转给 `amdl-ios-gateway`）。
/// 既然只有一个源站，可配置的就只该有**一个**主机地址：主 App、分享扩展和实时活动
/// 网关都从这里取，`/apns` 前缀由 `gatewayBaseURLString` 派生，不再单独存一份。
///
/// 放在 `LiveActivityShared/` 是为了让分享扩展也能引用同一份常量。以前三个文件
/// 各写一遍默认地址、靠人记得同步，而漏掉任何一个的后果都不一样地难查：主 App
/// 打错域名会立刻报错，**实时活动网关打错只会静悄悄地再也不出现进度条**。
nonisolated enum BackendEndpoint {
    static let appGroupIdentifier = "group.com.lyjw131.amdl.amdl-ios"

    /// Info.plist 里承载编译期主机名的键。值来自构建设置 `AMDL_PORTAL_HOST`，
    /// 而那个值由 `Config/Portal.xcconfig` 提供 —— 那个文件不进仓库。
    static let portalHostInfoKey = "AMDLPortalHost"

    /// 内置默认门户地址。**仓库里不存在这个地址**：主机名在编译期从
    /// `AMDL_PORTAL_HOST` 注入，没配就是空串，用户在「调试」页自己填。
    ///
    /// 只存主机名而不是整个 URL，是因为 xcconfig 把 `//` 当注释开头，
    /// `https://` 会被静默截断成 `https:`——一个能编译、能安装、只是永远连不上的
    /// 配置。scheme 在这里拼，那个坑就不存在。
    static var defaultBaseURLString: String {
        let host = (Bundle.main.object(forInfoDictionaryKey: portalHostInfoKey) as? String) ?? ""
        return defaultBaseURLString(host: host)
    }

    /// 纯函数版本，方便测试：测试 bundle 里没有这个键，走 `Bundle.main` 永远是空串。
    static func defaultBaseURLString(host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 允许把整个 URL 填进构建设置，虽然 xcconfig 里不好写、命令行覆盖时却很自然。
        guard !trimmed.contains("://") else { return trimmingTrailingSlashes(trimmed) }
        return "https://" + trimmingTrailingSlashes(trimmed)
    }

    /// 门户把这个前缀剥掉之后才转给 `amdl-ios-gateway`，那台机器只认识
    /// `/v1/...` 和 `/health`，所以实时活动的请求必须带上它。
    ///
    /// 剥前缀的活儿从 Traefik 搬到了门户：以前是 `amdl-apns-strip` 这个 stripPrefix
    /// 中间件，现在是门户策略表里的 `/apns/*` 那几行。`amdl-ios-gateway` 现在只在
    /// 内网，不经过门户就没有任何路径能注册设备令牌。
    static let apnsPathPrefix = "/apns"

    /// App Group 里存门户地址的键。主 App 和分享扩展共用这一个。
    static let baseURLKey = "backendBaseURL"

    /// 旧版本给实时活动网关单开的一个键，存在 standard defaults 里。现在只在
    /// 迁移时读一次就删。见 `migrateLegacyGatewayBaseURL()`。
    static let legacyGatewayBaseURLKey = "liveActivityGatewayBaseURL"

    /// 迁移时没法并进唯一设置、只能丢弃的旧网关地址，留给「调试」页说明情况。
    static let discardedGatewayBaseURLKey = "discardedLiveActivityGatewayBaseURL"

    /// 不缓存成 `static let`：`UserDefaults` 不是 `Sendable`，而这个类型要能从
    /// 通知服务扩展那种非 MainActor 的入口调用。`UserDefaults(suiteName:)` 内部
    /// 本来就有实例缓存，每次现取没有额外开销。
    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroupIdentifier) }

    /// 门户根地址，可在「调试」页修改；主 App 和分享扩展共用这个值。
    static var baseURLString: String {
        get {
            let appGroupValue = sharedDefaults?.string(forKey: baseURLKey)
            let legacyValue = UserDefaults.standard.string(forKey: baseURLKey)
            // 更早的版本把地址存在 standard defaults 里，这里搬进 App Group 让
            // 分享扩展也能读到。不改写具体地址：用户填什么用什么。
            if appGroupValue?.isEmpty ?? true, let legacyValue, !legacyValue.isEmpty {
                sharedDefaults?.set(legacyValue, forKey: baseURLKey)
            }
            return resolveBaseURLString(appGroupValue: appGroupValue, legacyValue: legacyValue)
        }
        set {
            sharedDefaults?.set(newValue, forKey: baseURLKey)
            UserDefaults.standard.set(newValue, forKey: baseURLKey)
        }
    }

    /// 取值优先级：App Group > 早期版本的 standard defaults > 内置默认。
    ///
    /// 纯函数，不碰 `UserDefaults`。测试必须走这一条：用例是并行跑的，往真实
    /// defaults 里写一个假地址，会让同批次里读地址的用例（`isGatewayHost`）跟着崩。
    static func resolveBaseURLString(appGroupValue: String?, legacyValue: String?) -> String {
        if let appGroupValue, !appGroupValue.isEmpty { return appGroupValue }
        if let legacyValue, !legacyValue.isEmpty { return legacyValue }
        return defaultBaseURLString
    }

    /// 实时活动网关地址：门户地址 + `/apns`。派生而来，没有独立的设置项。
    static var gatewayBaseURLString: String { apnsURLString(from: baseURLString) }

    /// 默认门户地址对应的网关地址。
    static var defaultGatewayBaseURLString: String { apnsURLString(from: defaultBaseURLString) }

    /// 把门户地址拼成 `/apns` 端点。
    static func apnsURLString(from base: String) -> String {
        let trimmed = trimmingTrailingSlashes(base)
        guard !trimmed.isEmpty else { return "" }
        // 用户把带 `/apns` 的旧地址填进唯一那个输入框时，不要叠成 `/apns/apns`。
        guard !trimmed.hasSuffix(apnsPathPrefix) else { return trimmed }
        return trimmed + apnsPathPrefix
    }

    /// 反向：把带 `/apns` 的网关地址还原成门户地址。
    static func portalURLString(fromGateway gateway: String) -> String {
        let trimmed = trimmingTrailingSlashes(gateway)
        guard trimmed.hasSuffix(apnsPathPrefix) else { return trimmed }
        return trimmingTrailingSlashes(String(trimmed.dropLast(apnsPathPrefix.count)))
    }

    private static func trimmingTrailingSlashes(_ value: String) -> String {
        var trimmed = value
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    // MARK: - 旧网关地址的迁移

    /// 升级到「一个域名」之后，旧的 `liveActivityGatewayBaseURL` 该怎么处理。
    enum GatewayMigration: Equatable {
        /// 没存过旧值，什么都不用做。
        case nothingToDo
        /// 旧值和从门户地址派生出来的结果一致，直接删键。
        case droppedRedundantValue
        /// 旧值是门户形状（带 `/apns`）而门户地址没被改过 —— 用户真正指定的就是
        /// 这台主机，把它的 origin 提上来当唯一设置。
        case adoptedPortalOrigin(String)
        /// 旧值指向另一台主机，合不进来。保留门户地址，把被丢弃的值记下来。
        case discarded(String)
    }

    /// 纯函数版本，方便测试：只根据两个输入决定结果，不碰 `UserDefaults`。
    ///
    /// - Parameters:
    ///   - legacyGateway: 旧的 `liveActivityGatewayBaseURL`，没存过就是 nil。
    ///   - storedPortal: App Group 里存着的门户地址，从没改过就是 nil。
    /// - Parameter builtInDefault: 内置默认门户地址。**必须能被注入**：自从主机名
    ///   改成编译期注入，`defaultBaseURLString` 在测试 bundle 里是空串，而这个
    ///   函数的分支恰好取决于它 —— 读环境值会让同一份逻辑在测试里和线上走不同的
    ///   路径，那种测试比没有还糟。
    static func gatewayMigration(
        legacyGateway: String?,
        storedPortal: String?,
        builtInDefault: String = defaultBaseURLString
    ) -> GatewayMigration {
        guard let legacyGateway, !trimmingTrailingSlashes(legacyGateway).isEmpty else {
            return .nothingToDo
        }

        let portal = storedPortal.map(trimmingTrailingSlashes) ?? ""
        let effectivePortal = portal.isEmpty ? builtInDefault : portal
        // 归一化之后再比：结尾斜杠、大小写不该算成"用户配了两个不同的地址"。
        let normalizedLegacy = apnsURLString(from: portalURLString(fromGateway: legacyGateway))
        if normalizedLegacy.caseInsensitiveCompare(apnsURLString(from: effectivePortal)) == .orderedSame {
            return .droppedRedundantValue
        }

        // 门户地址还是内置默认值，而旧网关地址带着 `/apns` —— 那就是一台门户形状
        // 的主机，用户唯一动过的设置就是它。把 origin 提上来，而不是把他默默退回
        // 生产域名。反过来，旧值要是**不带** `/apns`（典型是本地直连
        // `http://…:18081` 的调试配置），它就只是网关本身，不能拿来当门户地址：
        // 那样 `/api/v1` 会跟着搬家，把一套本来能用的配置改坏。
        if portal.isEmpty, trimmingTrailingSlashes(legacyGateway).hasSuffix(apnsPathPrefix) {
            let origin = portalURLString(fromGateway: legacyGateway)
            if !origin.isEmpty {
                return .adoptedPortalOrigin(origin)
            }
        }

        return .discarded(trimmingTrailingSlashes(legacyGateway))
    }

    /// 读旧键、按 `gatewayMigration(legacyGateway:storedPortal:)` 的结论落盘，然后
    /// 把旧键删掉。启动时跑一次即可（`AppDelegate`），删了键就不会再跑第二次。
    ///
    /// 旧键在 **standard** defaults 里，那是每个 target 各自的域 —— 只有主 App
    /// 写过它，所以迁移只能由主 App 做，结论写进 App Group 之后分享扩展才看得到。
    @discardableResult
    static func migrateLegacyGatewayBaseURL() -> GatewayMigration {
        let legacy = UserDefaults.standard.string(forKey: legacyGatewayBaseURLKey)
        let stored = sharedDefaults?.string(forKey: baseURLKey)
            ?? UserDefaults.standard.string(forKey: baseURLKey)
        let outcome = gatewayMigration(legacyGateway: legacy, storedPortal: stored)

        switch outcome {
        case .nothingToDo:
            return outcome
        case .droppedRedundantValue:
            break
        case let .adoptedPortalOrigin(origin):
            baseURLString = origin
        case let .discarded(old):
            sharedDefaults?.set(old, forKey: discardedGatewayBaseURLKey)
        }

        UserDefaults.standard.removeObject(forKey: legacyGatewayBaseURLKey)
        return outcome
    }

    /// 迁移时被丢弃的旧网关地址，「调试」页读它来提醒用户。
    static var discardedGatewayBaseURL: String? {
        let value = sharedDefaults?.string(forKey: discardedGatewayBaseURLKey)
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func clearDiscardedGatewayBaseURL() {
        sharedDefaults?.removeObject(forKey: discardedGatewayBaseURLKey)
    }
}
