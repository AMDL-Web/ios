//
//  AppleMusicLinks.swift
//  amdl-ios
//

import Foundation

/// 详情页上「标题 → Apple Music 专辑/单曲页」「艺人名 → Apple Music 艺人页」两个跳转。
///
/// 两条都不用查目录：标题用任务的 `input`（它本身就是那条链接），艺人页用后端解析
/// 时一并回填的 `artist_url`。后端拿的是 Apple 目录里 artist 资源的 `attributes.url`，
/// 比在 App 里另发一次 catalog 请求准，也不需要 MusicKit 授权。
///
/// `artist_url` 出现之前解析的老任务没有这个字段，那时退回 Apple Music 站内搜艺人
/// 名——落地页仍然是那个艺人，只是多一跳。
enum AppleMusicLinks {
    /// 任务本身在 Apple Music 上的页面。`input` 不是 http(s)（比如手输的
    /// `id:123`）时返回 nil，标题就不做成可点。
    static func collectionURL(for job: Job) -> URL? {
        guard let url = URL(string: job.input),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// 只有单曲和专辑的副标题是艺人名。歌单和电台那一行是策展人/提供方，没有对应的
    /// 艺人页；艺人任务本身没有副标题。
    static func canOpenArtistPage(for job: Job) -> Bool {
        job.type == .song || job.type == .album
    }

    /// Apple 给「没有单一艺人」的合辑填的占位艺人名。它不是一个人，落地页对用户没有
    /// 意义，所以名字照常显示，只是不做成可点的。
    ///
    /// 文案跟着曲库区域走：中文区是「群星」，其余区是「Various Artists」——`artist_name`
    /// 是后端原样透传 Apple 的 `attributes.artistName`（见 openapi.yaml），而 `storefront`
    /// 是从用户贴进来的链接里解析的，两种写法都能落到 App 上，所以两个都认。
    /// `DownloadDetailSummaryView` 在各曲艺人不一致时自己填的那个「群星」同理。
    static func isPlaceholderArtistName(_ name: String) -> Bool {
        placeholderArtistNames.contains(
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static let placeholderArtistNames: Set<String> = ["群星", "various artists"]

    /// 点艺人名要跳的地址：后端给了就直达艺人页，没给就站内搜这个名字。占位艺人两条
    /// 路都不给——即便 Apple 目录里真有那么一个「群星」资源，它也不是用户想去的地方。
    static func artistDestination(for job: Job, name: String) -> URL? {
        guard !isPlaceholderArtistName(name) else { return nil }
        if let artistURL = job.artistURL,
           let url = URL(string: artistURL),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }
        return searchURL(term: name, storefront: storefront(for: job))
    }

    /// 链接里的区域优先（跳转要落在同一个区），其次是任务记录的区域，都没有就按美区。
    private static func storefront(for job: Job) -> String {
        if let url = collectionURL(for: job) {
            let segments = url.path.split(separator: "/").map(String.init)
            // 区域码是路径第一段的两位字母，如 /cn/album/...
            if let first = segments.first, first.count == 2, first.allSatisfy(\.isLetter) {
                return first.lowercased()
            }
        }
        if let storefront = job.storefront?.trimmingCharacters(in: .whitespaces), !storefront.isEmpty {
            return storefront.lowercased()
        }
        return "us"
    }

    private static func searchURL(term: String, storefront: String) -> URL? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.apple.com"
        components.path = "/\(storefront)/search"
        components.queryItems = [URLQueryItem(name: "term", value: trimmed)]
        return components.url
    }
}
