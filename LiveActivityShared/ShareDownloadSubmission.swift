import Foundation

/// 一条链接对 media user token 的需求程度。
///
/// 后端的判据在 `amdl-backend/internal/jobs/manager.go` 的 `needsMediaUserToken`：
/// 电台一定要，`pl.u-` 开头的私人歌单会拿它去补封面，其余类型根本不会用到它
/// （提交时带了也会被 `WithoutMediaUserToken()` 剥掉）。
nonisolated enum MediaUserTokenNeed: Sendable, Equatable {
    /// 电台：没有令牌**一定失败**。后端解析曲目要调
    /// `POST /v1/me/stations/next-tracks/{id}`，那个接口必须带用户令牌，
    /// 缺了它 job 会排进队列、跑一圈、然后以
    /// `station downloads require a media_user_token` 失败。
    case required
    /// 私人歌单：令牌只用来补封面（后端那边是 best-effort 的库信息补全），
    /// 没有也能把歌下完，只是封面还是占位图——这正是这次报告里的第二个症状。
    case artworkOnly
    /// 其余链接：带不带都一样。
    case none
}

/// 分享扩展提交前对链接做的那一点点判断。
///
/// 这是 `amdl-backend/internal/applemusic/url.go` 的**手抄镜像**，和
/// `DownloadsAPI.swift` 镜像 `openapi.yaml` 是同一种关系：跨仓库没有任何东西会在
/// 编译期帮忙对齐，后端改了解析规则这边不会报错，只会开始判错。所以这里只抄
/// 「判断要不要令牌」需要的那几条，判不出来就一律退回 `.none` 让后端去裁决——
/// 拦错一条能下的链接，比放过一条下不了的更糟。
nonisolated enum AppleMusicShareLink {
    /// 和后端 `ParseWithAlbumTrackMode` 的主机白名单一致。
    private static let supportedHosts: Set<String> = [
        "music.apple.com",
        "beta.music.apple.com",
        "classical.music.apple.com",
    ]

    private static let classicalHost = "classical.music.apple.com"

    static func mediaUserTokenNeed(for url: URL) -> MediaUserTokenNeed {
        guard let host = url.host()?.lowercased(), supportedHosts.contains(host) else {
            return .none
        }
        // 后端要求 `/{区域}/{类型}/…/{id}` 至少三段，区域是两位字母。
        let segments = url.path.split(separator: "/").map(String.init)
        guard segments.count >= 3, let id = segments.last else { return .none }
        let storefront = segments[0].lowercased()
        guard storefront.count == 2, storefront.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return .none
        }

        switch segments[1].lowercased() {
        case "station":
            // classical 域名下的电台后端直接拒收（`unsupported Apple Music Classical
            // URL type`）。那不是「缺令牌」，把它拦在这里只会给出一句错误的原因，
            // 照常提交、让后端说真话。
            return host == classicalHost ? .none : .required
        case "playlist":
            return id.hasPrefix("pl.u-") ? .artworkOnly : .none
        default:
            return .none
        }
    }
}

/// `POST /api/v1/downloads` 的请求体——分享扩展用的那一份。
///
/// 主 App 走 `DownloadsAPI` 里的 `DownloadCreateRequest`；扩展 target 看不见
/// `DownloadsAPI.swift`，所以同一个 JSON 形状在这个仓库里有两份手抄。放在
/// `LiveActivityShared/` 而不是扩展里，一是不在扩展 target 里另起一份私有副本，
/// 二是这样单元测试才够得着它（测试 target 只依赖主 App）。
nonisolated struct ShareDownloadCreateRequest: Encodable, Sendable {
    let urls: [String]
    let overrides: Overrides?

    nonisolated struct Overrides: Encodable, Sendable {
        let mediaUserToken: String?

        enum CodingKeys: String, CodingKey {
            case mediaUserToken = "media_user_token"
        }
    }

    /// 没有令牌时**整个 `overrides` 都不发**。后端把 `media_user_token` 当三态处理
    /// （openapi.yaml：省略＝沿用 `catalog.media_user_token` fallback，空串＝显式清空），
    /// 发一个空串等于主动把后端的 fallback 关掉，比不发更糟。
    init(url: String, mediaUserToken: String?) {
        urls = [url]
        let trimmed = mediaUserToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        overrides = trimmed.isEmpty ? nil : Overrides(mediaUserToken: trimmed)
    }
}
