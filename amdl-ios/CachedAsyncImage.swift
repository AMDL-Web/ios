//
//  CachedAsyncImage.swift
//  amdl-ios
//
//  Created by OpenAI on 2026/7/6.
//

import SwiftUI
import UIKit

/// 两级图片缓存：内存 `NSCache` + 磁盘文件。
///
/// 单纯内存缓存在 App 被杀后就空了，重启必然重新下载封面——而且预签名的
/// blobstore 直链每次刷新都会变化，按整条 URL 作 key 永远命中不了。所以这里：
/// 1. 加磁盘持久化，重启后同 key 直接出图；
/// 2. key 由调用方传入稳定标识（如 `private-playlist:<ID>:<size>`），签名
///    URL 变了也能复用同一张图。
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    private let diskStore = ImageDiskStore(countLimit: 400)
    private var generation: UInt64 = 0
    private var downloadTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    private init() {}

    func memoryImage(forCacheKey key: String) -> UIImage? {
        guard !key.isEmpty else { return nil }
        return memory.object(forKey: key as NSString)
    }

    func image(forCacheKey key: String) async -> UIImage? {
        guard !key.isEmpty else { return nil }
        if let image = memoryImage(forCacheKey: key) { return image }
        let requestedGeneration = generation
        guard let data = await diskStore.data(
            forCacheKey: key,
            generation: requestedGeneration
        ),
              requestedGeneration == generation,
              let image = UIImage(data: data) else {
            return nil
        }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    func insert(_ image: UIImage, data: Data, forCacheKey key: String) async {
        guard !key.isEmpty else { return }
        let requestedGeneration = generation
        memory.setObject(image, forKey: key as NSString)
        await diskStore.insert(data, forCacheKey: key, generation: requestedGeneration)
    }

    /// 静默把图片写入两级缓存。同一个稳定 key 的并发请求会合并，避免列表中
    /// 多个预取窗口重复下载同一张大封面。
    func prefetch(url: URL?, forCacheKey key: String) async {
        guard !key.isEmpty, let url else { return }
        if await image(forCacheKey: key) != nil { return }
        if let pending = downloadTasks[key] {
            await pending.task.value
            return
        }

        let requestedGeneration = generation
        let taskID = UUID()
        let task = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let response = response as? HTTPURLResponse,
                   !(200..<300).contains(response.statusCode) {
                    return
                }
                guard !Task.isCancelled,
                      let image = UIImage(data: data),
                      let self,
                      requestedGeneration == self.generation else { return }
                await self.insert(image, data: data, forCacheKey: key)
            } catch {
                // 预取失败不打扰当前界面，真正展示时仍可再次尝试。
            }
        }
        downloadTasks[key] = (taskID, task)
        await task.value
        if downloadTasks[key]?.id == taskID {
            downloadTasks[key] = nil
        }
    }

    /// 清掉全部缓存：内存清空 + 删除整个磁盘缓存目录再重建。调试用。
    func clearAll() async {
        generation &+= 1
        for pending in downloadTasks.values {
            pending.task.cancel()
        }
        downloadTasks.removeAll()
        memory.removeAllObjects()
        await diskStore.clear(generation: generation)
    }
}

/// 串行化所有磁盘 I/O，避免读取、写入和清理同一个缓存文件时发生竞态。
private actor ImageDiskStore {
    private let root: URL
    private let countLimit: Int
    private var generation: UInt64 = 0

    init(countLimit: Int) {
        self.countLimit = countLimit
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func data(forCacheKey key: String, generation requestedGeneration: UInt64) -> Data? {
        guard prepare(for: requestedGeneration) else { return nil }
        return try? Data(contentsOf: diskURL(for: key))
    }

    func insert(_ data: Data, forCacheKey key: String, generation requestedGeneration: UInt64) {
        guard prepare(for: requestedGeneration) else { return }
        try? data.write(to: diskURL(for: key), options: .atomic)
        pruneIfNeeded()
    }

    func clear(generation requestedGeneration: UInt64) {
        guard requestedGeneration > generation else { return }
        generation = requestedGeneration
        removeAllFiles()
    }

    /// The first operation from a new cache generation performs the clear. This
    /// keeps a user-initiated clear ordered even when an older read/write was
    /// already waiting on the actor.
    private func prepare(for requestedGeneration: UInt64) -> Bool {
        guard requestedGeneration >= generation else { return false }
        if requestedGeneration > generation {
            generation = requestedGeneration
            removeAllFiles()
        }
        return true
    }

    private func removeAllFiles() {
        if let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for url in files {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func diskURL(for key: String) -> URL {
        root.appendingPathComponent(Self.stableHash(key))
    }

    /// key 里可能带签名 URL / 特殊字符，用 FNV-1a 64-bit 哈希做文件名。
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        return String(h, radix: 16)
    }

    private func pruneIfNeeded() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        guard urls.count > countLimit else { return }
        let sorted = urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        let toDelete = max(0, urls.count - countLimit)
        for url in sorted.prefix(toDelete) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// 带两级缓存的图片加载视图。
///
/// `cacheKey` 是稳定的缓存标识（与 URL 解耦），调用方应优先传入不会变的 key
/// （如 `private-playlist:<ID>:<size>`）；不传则退化为 URL 字符串。命中内存缓存
/// 时第一帧直接显示；磁盘缓存则由视图任务异步读取，避免阻塞主线程。
struct CachedAsyncImage: View {
    let url: URL?
    let cacheKey: String
    let fallbackCacheKey: String?

    @State private var uiImage: UIImage?

    init(url: URL?, cacheKey: String? = nil, fallbackCacheKey: String? = nil) {
        self.url = url
        let resolved = cacheKey ?? url?.absoluteString ?? ""
        self.cacheKey = resolved
        self.fallbackCacheKey = fallbackCacheKey == resolved ? nil : fallbackCacheKey
        _uiImage = State(
            initialValue: ImageCache.shared.memoryImage(forCacheKey: resolved)
                ?? fallbackCacheKey.flatMap {
                    ImageCache.shared.memoryImage(forCacheKey: $0)
                }
        )
    }

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: "\(cacheKey)|\(url?.absoluteString ?? "")") {
            await load()
        }
    }

    private func load() async {
        if let cached = await ImageCache.shared.image(forCacheKey: cacheKey) {
            guard !Task.isCancelled else { return }
            uiImage = cached
            return
        }
        guard !Task.isCancelled else { return }

        // Hero 大图还未下载完成时先沿用列表里已经显示过的较小封面，避免
        // zoom 转场结束后突然退回类型占位图；大图落入缓存后再原位替换。
        if let fallbackCacheKey,
           let fallback = await ImageCache.shared.image(forCacheKey: fallbackCacheKey) {
            guard !Task.isCancelled else { return }
            uiImage = fallback
        } else {
            // 视图身份未变但 url/cacheKey 换了内容（如详情页被导航复用去展示另一个
            // 任务）：旧 key 的图不能继续挂着，否则会把上一个任务的封面当成当前的。
            uiImage = nil
        }

        guard !Task.isCancelled else { return }
        await ImageCache.shared.prefetch(url: url, forCacheKey: cacheKey)
        guard !Task.isCancelled else { return }
        if let image = await ImageCache.shared.image(forCacheKey: cacheKey) {
            uiImage = image
        }
    }
}
