//
//  PrivatePlaylistArtworkStore.swift
//  amdl-ios
//

import Foundation
import MusicKit
import UIKit

/// 私有歌单封面的 stale-while-revalidate 缓存。
///
/// 优先使用任务的 `artwork_url`。如果后端以后返回 S3 预签名链接，会先按链接
/// 自己的有效期校验；链接过期后才按公开歌单 ID 请求一次 `include=library`。
/// 普通后端 URL 视为稳定链接，不会被人为设置刷新 TTL。
/// 刷新期间继续使用已经下载的旧图；新图下载并解码成功后才替换稳定图片缓存。
@MainActor
final class PrivatePlaylistArtworkStore {
    static let shared = PrivatePlaylistArtworkStore()

    struct Request: Hashable {
        let storefront: String
        let playlistID: String
        let pixelSize: Int
        let usesSizeInvariantCache: Bool

        var key: String {
            let base = "\(storefront.lowercased())|\(playlistID)"
            return usesSizeInvariantCache ? base : "\(base)|\(pixelSize)"
        }

        var imageCacheKey: String {
            let base = "private-playlist:\(playlistID)"
            return usesSizeInvariantCache ? base : "\(base):\(pixelSize)"
        }
    }

    private struct Entry: Codable {
        let url: String
        let refreshAfter: Date
    }

    private struct DiskPayload: Codable {
        let entries: [String: Entry]
    }

    private struct CatalogPlaylistResponse: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable {
                struct Artwork: Decodable { let url: String? }
                let artwork: Artwork?
            }

            struct Relationships: Decodable {
                struct Library: Decodable {
                    struct Resource: Decodable {
                        struct Attributes: Decodable {
                            struct Artwork: Decodable { let url: String? }
                            let artwork: Artwork?
                        }
                        let attributes: Attributes?
                    }
                    let data: [Resource]
                }
                let library: Library?
            }

            let attributes: Attributes?
            let relationships: Relationships?
        }

        let data: [Resource]
    }

    private var entries: [String: Entry] = [:]
    private var refreshTasks: [String: Task<URL?, Never>] = [:]

    private init() {
        loadFromDisk()
        removeLegacyLibraryCache()
    }

    static func request(for job: Job, pixelSize: Int) -> Request? {
        guard job.type == .playlist,
              let url = URL(string: job.input),
              let playlistID = url.pathComponents.last,
              playlistID.lowercased().hasPrefix("pl.u-") else {
            return nil
        }

        let pathStorefront = url.pathComponents.dropFirst().first
        guard let storefront = firstNonEmpty(job.storefront, pathStorefront) else { return nil }
        // 私人歌单的 S3 封面是无尺寸占位符的原图直链；列表和详情页应共用
        // 同一份缓存。Apple Music 模板仍按请求尺寸分别缓存。
        let artworkTemplate = job.artworkURL ?? ""
        let usesSizeInvariantCache = !artworkTemplate.isEmpty
            && !artworkTemplate.contains("{w}")
            && !artworkTemplate.contains("{h}")
        return Request(
            storefront: storefront,
            playlistID: playlistID,
            pixelSize: pixelSize,
            usesSizeInvariantCache: usesSizeInvariantCache
        )
    }

    /// 仅在稳定图片缓存确实有旧图时返回 URL。URL 即使已经过期也没关系：
    /// `CachedAsyncImage` 会先命中本地图片，不会拿过期 URL 覆盖当前画面。
    func cachedURL(for request: Request) async -> URL? {
        guard await ImageCache.shared.image(forCacheKey: request.imageCacheKey) != nil,
              let value = entries[request.key]?.url else {
            return nil
        }
        return URL(string: value)
    }

    /// 静默刷新封面。后端返回的 URL 更新或缓存到期时才工作；任何失败都保留旧图。
    func refreshIfNeeded(for request: Request, backendURL: URL?) async -> URL? {
        if let refreshTask = refreshTasks[request.key] {
            return await refreshTask.value
        }

        let hasCachedImage = await ImageCache.shared.image(forCacheKey: request.imageCacheKey) != nil
        if let refreshTask = refreshTasks[request.key] {
            return await refreshTask.value
        }

        let current = entries[request.key]
        var candidate = preferredBackendCandidate(backendURL, over: current)
        let backendNeedsRefresh = backendURL.map { Self.refreshDate(for: $0) <= Date() } ?? false
        if candidate == nil, let current, current.refreshAfter > Date(), !hasCachedImage,
           !backendNeedsRefresh {
            candidate = URL(string: current.url)
        }
        if candidate == nil, let current, current.refreshAfter > Date(), hasCachedImage,
           !backendNeedsRefresh {
            return nil
        }

        let task = Task<URL?, Never> {
            do {
                let url: URL
                if let candidate {
                    url = candidate
                } else {
                    url = try await Self.fetchArtworkURL(for: request)
                }
                let refreshAfter = Self.refreshDate(for: url)
                guard refreshAfter > Date() else { return nil }

                let (data, response) = try await URLSession.shared.data(from: url)
                if let response = response as? HTTPURLResponse,
                   !(200..<300).contains(response.statusCode) {
                    return nil
                }
                guard let image = UIImage(data: data) else { return nil }

                // 内存缓存同步替换；磁盘缓存随后原子写入。到这里才通知视图换图。
                await ImageCache.shared.insert(image, data: data, forCacheKey: request.imageCacheKey)
                entries[request.key] = Entry(url: url.absoluteString, refreshAfter: refreshAfter)
                saveToDisk()
                return url
            } catch {
                return nil
            }
        }

        refreshTasks[request.key] = task
        let result = await task.value
        refreshTasks[request.key] = nil
        return result
    }

    func clearCache() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: Self.storageURL)
    }

    /// 从 S3/Blobstore 的签名时间和有效秒数计算实际失效时间。
    static func signedURLExpiration(_ url: URL) -> Date? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let dateString = items.first(where: { $0.name.caseInsensitiveCompare("X-Amz-Date") == .orderedSame })?.value,
              let expiresString = items.first(where: { $0.name.caseInsensitiveCompare("X-Amz-Expires") == .orderedSame })?.value,
              let expires = TimeInterval(expiresString) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let signedAt = formatter.date(from: dateString) else { return nil }
        return signedAt.addingTimeInterval(expires)
    }

    private func preferredBackendCandidate(_ url: URL?, over current: Entry?) -> URL? {
        guard let url else { return nil }
        let candidateRefresh = Self.refreshDate(for: url)
        guard candidateRefresh > Date() else { return nil }
        guard let current else { return url }
        if current.url == url.absoluteString { return nil }

        let currentURL = URL(string: current.url)
        let candidateIsSigned = Self.signedURLExpiration(url) != nil
        let currentIsSigned = currentURL.flatMap(Self.signedURLExpiration) != nil
        // A changed backend URL wins when either side is a stable URL. When both
        // are signed, keep a locally refreshed URL unless the backend one lasts longer.
        if !candidateIsSigned || !currentIsSigned { return url }
        return candidateRefresh > current.refreshAfter ? url : nil
    }

    private static func fetchArtworkURL(for request: Request) async throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.music.apple.com"
        components.path = "/v1/catalog/\(request.storefront)/playlists/\(request.playlistID)"
        components.queryItems = [URLQueryItem(name: "include", value: "library")]
        guard let url = components.url else { throw ArtworkError.invalidURL }

        let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        let payload = try JSONDecoder().decode(CatalogPlaylistResponse.self, from: response.data)
        guard let playlist = payload.data.first else { throw ArtworkError.missingArtwork }

        // pl.u- 歌单的 catalog 封面可能是 Apple 生成的曲目拼贴;library 关系里
        // 才是用户自选的真封面,优先使用。
        let template = playlist.relationships?.library?.data.lazy.compactMap { $0.attributes?.artwork?.url }.first
            ?? playlist.attributes?.artwork?.url
        guard let template, !template.isEmpty,
              let artworkURL = resolveArtworkTemplate(template, pixelSize: request.pixelSize) else {
            throw ArtworkError.missingArtwork
        }
        return artworkURL
    }

    private static func resolveArtworkTemplate(_ template: String, pixelSize: Int) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{w}", with: String(pixelSize))
            .replacingOccurrences(of: "{h}", with: String(pixelSize))
            .replacingOccurrences(of: "{f}", with: "jpg"))
    }

    /// 提前五分钟刷新，避免图片下载途中签名失效。非签名图片视为稳定 URL。
    private static func refreshDate(for url: URL) -> Date {
        guard let expiration = signedURLExpiration(url) else {
            return .distantFuture
        }
        return expiration.addingTimeInterval(-5 * 60)
    }

    private static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("private-playlist-artwork.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data) else { return }
        var migrated = false
        entries = payload.entries.mapValues { entry in
            guard let url = URL(string: entry.url) else { return entry }
            let refreshAfter = Self.refreshDate(for: url)
            if refreshAfter != entry.refreshAfter { migrated = true }
            return Entry(url: entry.url, refreshAfter: refreshAfter)
        }
        if migrated { saveToDisk() }
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(DiskPayload(entries: entries)) else { return }
        let directory = Self.storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    private func removeLegacyLibraryCache() {
        let legacyURL = Self.storageURL.deletingLastPathComponent().appendingPathComponent("user-playlists.json")
        try? FileManager.default.removeItem(at: legacyURL)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private enum ArtworkError: Error {
        case invalidURL
        case missingArtwork
    }
}
