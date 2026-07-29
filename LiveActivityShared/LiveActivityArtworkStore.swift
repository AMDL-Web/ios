import CryptoKit
import Foundation

/// 纯静态的文件读写，没有任何共享可变状态，因此显式 `nonisolated`：通知服务
/// 扩展的入口回调不在 MainActor 上，需要能直接调用这里的方法。
nonisolated enum LiveActivityArtworkStore {
    static let appGroupIdentifier = "group.com.lyjw131.amdl.amdl-ios"
    private static let cacheDirectoryName = "LiveActivityArtwork-v2"

    static func data(for artworkURL: String) -> Data? {
        guard let fileURL = fileURL(for: artworkURL) else { return nil }
        return try? Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    static func contains(_ artworkURL: String) -> Bool {
        guard let fileURL = fileURL(for: artworkURL) else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func store(_ data: Data, for artworkURL: String) throws {
        guard let fileURL = fileURL(for: artworkURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    static func resolvedRemoteURL(from template: String, pixelSize: Int = 384) -> URL? {
        let size = String(pixelSize)
        let resolved = template
            .replacingOccurrences(of: "{w}", with: size)
            .replacingOccurrences(of: "{h}", with: size)
            .replacingOccurrences(of: "{f}", with: "jpg")
        guard let url = URL(string: resolved),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    static func fileURL(for artworkURL: String) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        let digest = SHA256.hash(data: Data(artworkURL.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return container
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
            .appendingPathComponent("\(digest).jpg", isDirectory: false)
    }
}
