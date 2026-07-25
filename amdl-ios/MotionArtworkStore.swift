//
//  MotionArtworkStore.swift
//  amdl-ios
//

import Foundation
import MusicKit

/// Apple Music 动态封面（motion artwork）的解析与缓存。
///
/// 部分专辑在 catalog 的 `attributes.editorialVideo` 下挂着一段方形 HLS 循环
/// 视频，Apple Music 自己的专辑页就是用它盖住静态封面的。两个要点：
///
/// 1. `editorialVideo` 是**扩展属性**，不写 `extend=editorialVideo` 时整个字段
///    不出现——不是「这张专辑没有」，是根本没请求。
/// 2. 纯 developer token 取不到它。实测同一张专辑在 cn/jp/us/gb 四个 storefront
///    下都返回空，而网页端有；所以这里必须走 `MusicDataRequest`，由 MusicKit
///    带上订阅者的 user token。没登录 Apple Music 时拿不到动态封面是预期行为，
///    静态封面照常显示。
///
/// 视频本身在 `mvod.itunes.apple.com` 上免鉴权公开，URL 不带签名参数，所以
/// 缓存可以放心存久一点，不需要像 [PrivatePlaylistArtworkStore] 那样按签名有效期
/// 刷新。
@MainActor
final class MotionArtworkStore {
    static let shared = MotionArtworkStore()

    /// 命中后缓存 30 天；确认没有动态封面则只缓存 3 天，这样后来才补上动态封面的
    /// 专辑不会被一次否定结果永久钉死。
    private static let positiveTTL: TimeInterval = 30 * 24 * 60 * 60
    private static let negativeTTL: TimeInterval = 3 * 24 * 60 * 60

    struct Request: Hashable {
        let storefront: String
        let albumID: String

        var key: String { "\(storefront.lowercased())|\(albumID)" }
    }

    struct MotionArtwork: Codable, Equatable {
        /// HLS master playlist。方形，24fps，360×360 到 1080×1080 多档。
        let videoURL: String

        var video: URL? { URL(string: videoURL) }
    }

    private struct Entry: Codable {
        /// nil 表示「查过了，这张专辑没有动态封面」。
        let artwork: MotionArtwork?
        let expiresAt: Date
    }

    private struct DiskPayload: Codable {
        let entries: [String: Entry]
    }

    private struct CatalogAlbumResponse: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable {
                struct EditorialVideo: Decodable {
                    struct Clip: Decodable {
                        let video: String?
                    }

                    /// 专辑详情页用的方形版本，与 hero 封面比例一致。
                    let motionDetailSquare: Clip?
                    /// 少数专辑只给了这一个方形变体。
                    let motionSquareVideo1x1: Clip?
                }

                let editorialVideo: EditorialVideo?
            }

            let attributes: Attributes?
        }

        let data: [Resource]
    }

    private var entries: [String: Entry] = [:]
    private var fetchTasks: [String: Task<MotionArtwork?, Never>] = [:]

    private init() {
        loadFromDisk()
    }

    /// 从任务解析出专辑请求。只有专辑和单曲有动态封面——单曲用的是它所属专辑的
    /// 那一段，和任务展示的静态封面同源。
    static func request(for job: Job) -> Request? {
        guard job.type == .album || job.type == .song,
              let url = URL(string: job.input) else { return nil }

        let components = url.pathComponents.filter { $0 != "/" }
        guard let albumIndex = components.firstIndex(where: { $0.lowercased() == "album" })
        else { return nil }

        // 形如 /cn/album/<slug>/<id> 或 /cn/album/<id>，取 album 之后最后一段纯数字。
        guard let albumID = components[components.index(after: albumIndex)...]
            .last(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }

        let pathStorefront = albumIndex > 0 ? components[components.index(before: albumIndex)] : nil
        guard let storefront = firstNonEmpty(job.storefront, pathStorefront) else { return nil }

        return Request(storefront: storefront, albumID: albumID)
    }

    /// 未过期的缓存结果。返回 `.some(nil)` 表示确认没有动态封面，`nil` 表示还没查过。
    func cached(for request: Request) -> MotionArtwork?? {
        guard let entry = entries[request.key], entry.expiresAt > Date() else { return nil }
        return .some(entry.artwork)
    }

    /// 解析动态封面。同一张专辑的并发请求会合并；任何失败都当作「暂时没有」，
    /// 不写入否定缓存，以免一次网络抖动把专辑钉死三天。
    func motionArtwork(for request: Request) async -> MotionArtwork? {
        if let cached = cached(for: request) { return cached }
        if let running = fetchTasks[request.key] { return await running.value }

        let task = Task<MotionArtwork?, Never> {
            do {
                let artwork = try await Self.fetchMotionArtwork(for: request)
                store(artwork, for: request)
                return artwork
            } catch {
                // 未登录 Apple Music、无订阅、网络失败都会走到这里。静态封面继续用。
                return nil
            }
        }

        fetchTasks[request.key] = task
        let artwork = await task.value
        fetchTasks[request.key] = nil
        return artwork
    }

    private func store(_ artwork: MotionArtwork?, for request: Request) {
        let ttl = artwork == nil ? Self.negativeTTL : Self.positiveTTL
        entries[request.key] = Entry(artwork: artwork, expiresAt: Date().addingTimeInterval(ttl))
        saveToDisk()
    }

    private static func fetchMotionArtwork(for request: Request) async throws -> MotionArtwork? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.music.apple.com"
        components.path = "/v1/catalog/\(request.storefront)/albums/\(request.albumID)"
        components.queryItems = [URLQueryItem(name: "extend", value: "editorialVideo")]
        guard let url = components.url else { throw MotionArtworkError.invalidURL }

        let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
        let payload = try JSONDecoder().decode(CatalogAlbumResponse.self, from: response.data)

        guard let video = payload.data.first?.attributes?.editorialVideo,
              let clip = video.motionDetailSquare ?? video.motionSquareVideo1x1,
              let videoURL = clip.video, !videoURL.isEmpty else {
            return nil
        }

        return MotionArtwork(videoURL: videoURL)
    }

    /// 调试用：清掉全部动态封面缓存。
    func clearAll() {
        entries.removeAll()
        for task in fetchTasks.values { task.cancel() }
        fetchTasks.removeAll()
        try? FileManager.default.removeItem(at: Self.storageURL)
    }

    private static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("motion-artwork.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data) else { return }
        let now = Date()
        entries = payload.entries.filter { $0.value.expiresAt > now }
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(DiskPayload(entries: entries)) else { return }
        let directory = Self.storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    private enum MotionArtworkError: Error {
        case invalidURL
    }
}
