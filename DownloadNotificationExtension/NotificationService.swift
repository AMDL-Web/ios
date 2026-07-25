import Intents
import OSLog
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

/// 扩展的 print 不会出现在任何可读的位置，用统一日志方便排查“横幅没出封面”。
private nonisolated let log = Logger(subsystem: "com.lyjw131.amdl.amdl-ios", category: "NotificationArtwork")

/// 下载完成通知的富媒体加工：网关在 payload 里带上 `artwork_url`，这里把封面下载
/// 下来，用 communication notification（`INSendMessageIntent`）把它作为“发信人头像”
/// 送进通知，于是横幅左侧原本固定的 App 图标就换成了任务封面，App 图标缩为角标。
/// 这是 iOS 唯一允许第三方 App 替换该图标的途径，需要主 App 具备
/// Communication Notifications 权限；一旦该路径不可用（权限缺失、图片异常），
/// 退回成普通的通知附件，封面显示在横幅右侧。
///
/// 没有封面、下载失败或超时都不需要兜底分支：只要在时限内没有调用
/// `contentHandler`，或者交回未修改的内容，系统就按原始通知投递。
/// 整个类型 `nonisolated`：目标默认隔离是 MainActor，而
/// `UNNotificationServiceExtension` 及其入口回调都不是，子类必须与父类的隔离一致。
nonisolated final class NotificationService: UNNotificationServiceExtension {

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        guard let raw = request.content.userInfo["artwork_url"] as? String,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            log.info("通知没有可用的封面地址，按原样投递")
            contentHandler(content)
            return
        }
        // 实时活动可能已经把同一张封面缓存进 App Group，此时无需再下载。
        guard let fileURL = Self.cachedArtworkFile(for: raw, remote: url) else {
            log.error("下载或缓存封面失败")
            contentHandler(content)
            return
        }
        // 二选一，不能兼得：`updating(from:)` 会丢掉 attachments，所以封面要么当
        // 图标（communication notification），要么当附件（横幅右侧缩略图）。
        if let updated = Self.contentWithArtworkIcon(content, artwork: fileURL) {
            log.info("已把封面设为通知图标")
            contentHandler(updated)
            return
        }
        if let attachment = Self.artworkAttachment(from: fileURL) {
            content.attachments = [attachment]
            log.info("无法替换通知图标，已退回封面附件")
        }
        contentHandler(content)
    }

    /// 封面必须落在 App Group 共享容器里：渲染通知的是系统进程，`INImage` 只有
    /// 拿到它能读到的文件地址才会真正显示，内联的图片数据会被静默丢弃。
    /// 这里直接复用实时活动那套共享缓存，命中时连下载都省了。
    private static func cachedArtworkFile(for template: String, remote url: URL) -> URL? {
        guard let fileURL = LiveActivityArtworkStore.fileURL(for: template) else { return nil }
        if LiveActivityArtworkStore.contains(template) {
            return fileURL
        }
        guard let data = fetch(url) else { return nil }
        guard ArtworkFormat(data: data) != nil else {
            log.error("封面不是 JPEG/PNG：\(data.count) 字节")
            return nil
        }
        do {
            try LiveActivityArtworkStore.store(data, for: template)
            return fileURL
        } catch {
            log.error("写入共享封面缓存失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 把封面包装成 communication notification 的发信人头像。文案不变：发信人名
    /// 就是原标题，消息正文就是原正文，只有左侧图标从 App 图标换成封面。
    private static func contentWithArtworkIcon(
        _ content: UNMutableNotificationContent,
        artwork fileURL: URL
    ) -> UNNotificationContent? {
        let jobID = content.userInfo["job_id"] as? String
        let image = INImage(url: fileURL)
        let sender = INPerson(
            personHandle: INPersonHandle(value: jobID ?? "amdl", type: .unknown),
            nameComponents: nil,
            displayName: content.title,
            image: image,
            contactIdentifier: nil,
            customIdentifier: jobID
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            // 每个任务独立成一段“会话”，不同专辑的通知不会被系统并到一起。
            conversationIdentifier: jobID,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        intent.setImage(image, forParameterNamed: \.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        do {
            return try content.updating(from: intent)
        } catch {
            log.error("communication notification 不可用：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func artworkAttachment(from cached: URL) -> UNNotificationAttachment? {
        guard let data = try? Data(contentsOf: cached),
              let format = ArtworkFormat(data: data)
        else { return nil }
        // 附件文件会被系统移走，所以不能直接交出共享缓存里的那份；复制到每次调用
        // 独占的临时目录，顺便按魔数给出正确的扩展名和类型。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("artwork", isDirectory: false)
            .appendingPathExtension(format.fileExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return try UNNotificationAttachment(
                identifier: "artwork",
                url: fileURL,
                options: [UNNotificationAttachmentOptionsTypeHintKey: format.typeIdentifier]
            )
        } catch {
            log.error("写入或挂载封面附件失败：\(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    /// 同步下载。扩展的总预算约 30 秒且此处没有别的工作，阻塞等待比把
    /// 系统交来的非 Sendable 回调搬进并发上下文更简单，也更好推理。
    private static func fetch(_ url: URL) -> Data? {
        let result = Mutex<Data?>(nil)
        let finished = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { finished.signal() }
            guard let data,
                  !data.isEmpty,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return }
            result.withLock { $0 = data }
        }
        task.resume()
        if finished.wait(timeout: .now() + 15) == .timedOut {
            task.cancel()
            return nil
        }
        return result.withLock { $0 }
    }
}

/// 附件必须带上正确的类型，否则系统会拒绝它；后端封面通常是 JPEG，但不保证。
private nonisolated enum ArtworkFormat {
    case jpeg
    case png

    init?(data: Data) {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            self = .png
        } else {
            return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        }
    }

    var typeIdentifier: String {
        switch self {
        case .jpeg: UTType.jpeg.identifier
        case .png: UTType.png.identifier
        }
    }
}
