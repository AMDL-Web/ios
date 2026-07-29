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
            // 占位一直垫在最底下，`CachedAsyncImage` 在真正解出 UIImage 之前画的是
            // Color.clear —— 这样封面槽位从头到尾都有东西，不会先闪一下白底。
            JobArtworkPlaceholder(job: job)

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

/// 封面还没到位时垫在下面的空槽位。
///
/// 以前是「任务类型色满铺 + 白色符号」：专辑是橙、歌单是粉，和失败态的红同属一段
/// 色相，一张只是还在加载的封面看上去像是出错了；一整块纯色也容易被当成一张真的
/// 纯色封面。现在是一块低饱和的浅色斜纹 —— 退到背景里，但一眼看得出是「这里还没有
/// 图」而不是「图坏了」。底色的色相按任务 id 定，和 Web 端占位一个思路：一屏都没有
/// 封面时各张专辑仍然彼此可分，只是强度收到了背景噪声的量级。
private struct JobArtworkPlaceholder: View {
    let job: Job

    @Environment(\.colorScheme) private var colorScheme

    /// 可选色相。刻意跳过红橙那一段，免得又和失败态的红归到一类里去。
    private static let hues: [Double] = [46, 88, 152, 190, 214, 258, 304]

    /// 同一个任务永远落在同一个色相上。FNV-1a，和 `ImageDiskStore` 里的文件名哈希同款。
    private var hue: Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in job.id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return Self.hues[Int(hash % UInt64(Self.hues.count))] / 360
    }

    private var fillColor: Color {
        colorScheme == .dark
            ? Color(hue: hue, saturation: 0.20, brightness: 0.20)
            : Color(hue: hue, saturation: 0.11, brightness: 0.93)
    }

    private var stripeColor: Color {
        colorScheme == .dark ? .white.opacity(0.05) : .white.opacity(0.55)
    }

    private var glyphColor: Color {
        colorScheme == .dark ? .white.opacity(0.26) : .black.opacity(0.18)
    }

    var body: some View {
        // 尺寸仍由 Rectangle 决定（列表 56pt、详情页整幅），纹路和符号放进 overlay
        // 按实际边长缩放 —— overlay 不参与布局，两种尺寸下的疏密与字号才能一致。
        Rectangle()
            .fill(fillColor)
            .overlay {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    let spacing = max(7, side * 0.055)
                    ZStack {
                        DiagonalHatch(spacing: spacing)
                            // 斜纹垂直间距是 spacing 的 √2/2，取一半线宽即明暗各占一半。
                            .stroke(stripeColor, lineWidth: spacing * 0.354)
                        Image(systemName: job.type.symbolName)
                            .font(.system(size: max(13, side * 0.2), weight: .medium))
                            .foregroundStyle(glyphColor)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
    }
}

/// 45° 等距斜纹，和 Web 端占位（index.css 里的 `.hatch`）是同一套纹路。
private struct DiagonalHatch: Shape {
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
