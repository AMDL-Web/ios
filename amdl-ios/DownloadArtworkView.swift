//
//  DownloadArtworkView.swift
//  amdl-ios
//

import SwiftUI
import UIKit

@MainActor
enum JobArtworkLoader {
    /// 与详情页 Hero 封面一致：按显示原生像素的 2 倍请求并缓存大图。
    static var heroPixelSize: Int {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let screen = windowScenes.first { $0.activationState == .foregroundActive }?.screen
            ?? windowScenes.first?.screen
        let width = screen?.bounds.width ?? 393
        let scale = screen?.scale ?? 3
        let side = max(width - 132, 200)
        return Int((side * scale * 2).rounded(.up))
    }

    static func cacheKey(for job: Job, pixelSize: Int) -> String {
        if let request = PrivatePlaylistArtworkStore.request(for: job, pixelSize: pixelSize) {
            return request.imageCacheKey
        }
        if let template = job.artworkURL, !template.isEmpty {
            return "artwork:\(template):\(pixelSize)"
        }
        return ""
    }

    static func prefetch(job: Job, pixelSize: Int) async {
        let primaryURL = job.artworkURL(pixelSize: pixelSize)
        if let request = PrivatePlaylistArtworkStore.request(for: job, pixelSize: pixelSize) {
            _ = await PrivatePlaylistArtworkStore.shared.refreshIfNeeded(
                for: request,
                backendURL: primaryURL
            )
            return
        }
        await ImageCache.shared.prefetch(
            url: primaryURL,
            forCacheKey: cacheKey(for: job, pixelSize: pixelSize)
        )
    }
}

/// 任务级封面。私有歌单使用稳定图片缓存，并按预签名 URL 的有效期静默刷新；
/// 其他任务直接使用后端的 artwork_url。
struct JobArtworkView: View {
    let job: Job
    var pixelSize: Int = 256

    @State private var fallbackURL: URL?
    @State private var artworkRevision = 0

    private var primaryURL: URL? {
        job.artworkURL(pixelSize: pixelSize)
    }

    private var privateRequest: PrivatePlaylistArtworkStore.Request? {
        PrivatePlaylistArtworkStore.request(for: job, pixelSize: pixelSize)
    }

    /// 稳定缓存 key，与签名 URL 解耦：
    /// - 后端封面：用原始模板字符串（未替换 {w}/{h} 的形式）和请求尺寸；
    /// - 私人歌单 S3 直链：`private-playlist:<公开id>`，没有尺寸之分，列表与详情
    ///   共用一份；Apple Music 尺寸模板仍在 key 末尾保留请求尺寸。
    private var cacheKey: String {
        JobArtworkLoader.cacheKey(for: job, pixelSize: pixelSize)
    }

    /// 详情大图尚未准备好时先复用概览封面的缓存，避免 zoom 动画结束后
    /// 短暂或永久露出任务类型占位图。
    private var fallbackCacheKey: String? {
        let overviewKey = JobArtworkLoader.cacheKey(for: job, pixelSize: 256)
        return overviewKey == cacheKey ? nil : overviewKey
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(job.type.tint.gradient)
                .overlay {
                    Image(systemName: job.type.symbolName)
                        .foregroundStyle(.white)
                }

            // 即便 fallbackURL 还没解析出来，只要本地缓存里有这个 key 的图，
            // CachedAsyncImage 就会优先加载缓存，不会用过期 URL 覆盖当前画面。
            CachedAsyncImage(
                url: privateRequest == nil ? primaryURL : fallbackURL,
                cacheKey: cacheKey,
                fallbackCacheKey: fallbackCacheKey
            )
            .id("\(cacheKey)|\(artworkRevision)")
        }
        .task(id: "\(job.id)|\(job.artworkURL ?? "")|\(pixelSize)") {
            await loadPrivatePlaylistArtwork()
        }
    }

    private func loadPrivatePlaylistArtwork() async {
        guard let privateRequest else { return }
        let store = PrivatePlaylistArtworkStore.shared
        fallbackURL = await store.cachedURL(for: privateRequest)
        guard !Task.isCancelled else { return }
        if let refreshedURL = await store.refreshIfNeeded(
            for: privateRequest,
            backendURL: primaryURL
        ) {
            guard !Task.isCancelled else { return }
            fallbackURL = refreshedURL
            artworkRevision &+= 1
        }
    }
}
