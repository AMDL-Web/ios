//
//  DownloadDetailCache.swift
//  amdl-ios
//

import Foundation

/// 任务详情磁盘缓存管理。Codable 编解码在主调用方进行（DownloadDetail 的
/// Codable 遵循是 MainActor 隔离的），本 actor 只负责串行磁盘 I/O。
actor DownloadDetailCache {
    static let shared = DownloadDetailCache()

    private let root: URL
    private let countLimit: Int

    init(countLimit: Int = 100) {
        self.countLimit = countLimit
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("DownloadDetailCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func loadData(jobID: String) -> Data? {
        guard !jobID.isEmpty else { return nil }
        let fileURL = cacheFileURL(for: jobID)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return data
    }

    func storeData(_ data: Data, jobID: String) {
        guard !jobID.isEmpty else { return }
        let fileURL = cacheFileURL(for: jobID)
        try? data.write(to: fileURL, options: .atomic)
        pruneIfNeeded()
    }

    private func cacheFileURL(for jobID: String) -> URL {
        root.appendingPathComponent(Self.stableHash(jobID) + ".json")
    }

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
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
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
