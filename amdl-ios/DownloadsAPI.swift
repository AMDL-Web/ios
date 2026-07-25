//
//  DownloadsAPI.swift
//  amdl-ios
//
//  Created by OpenAI on 2026/7/6.
//

import Foundation
import SwiftUI

enum JobType: String, Codable {
    case song, album, playlist, artist, station

    var symbolName: String {
        switch self {
        case .song: "music.note"
        case .album: "square.stack.fill"
        case .playlist: "music.note.list"
        case .artist: "person.fill"
        case .station: "dot.radiowaves.left.and.right"
        }
    }

    var tint: Color {
        switch self {
        case .song: .indigo
        case .album: .orange
        case .playlist: .pink
        case .artist: .teal
        case .station: .blue
        }
    }
}

extension Color {
    /// 解析 Apple Music artwork 配色的十六进制 RGB 字符串（如 "1a1a1a"，可容忍带 #）。
    init?(hexRGB: String?) {
        guard var hex = hexRGB?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum JobStatus: String, Codable {
    case queued, running, completed, failed, cancelled

    var isActive: Bool {
        self == .queued || self == .running
    }
}

struct Job: Codable, Identifiable {
    let id: String
    let input: String
    let type: JobType
    var storefront: String?
    var title: String?
    var artworkURL: String?
    let force: Bool
    var status: JobStatus
    var totalItems: Int
    var doneItems: Int
    var failedItems: Int
    var error: String?
    let createdAt: Date
    var updatedAt: Date
    /// 后端解析 input 后回填的展示元数据；旧后端或未解析完成时为 nil。
    var artistName: String? = nil
    var curatorName: String? = nil
    /// YYYY-MM-DD。
    var releaseDate: String? = nil
    var genre: String? = nil
    /// Apple Music attributes.artwork 的配色（十六进制 RGB，不带 #）：
    /// 封面主背景色与四档配套文字颜色，按对比度从强到弱排列。
    var artworkBgColor: String? = nil
    var artworkTextColor1: String? = nil
    var artworkTextColor2: String? = nil
    var artworkTextColor3: String? = nil
    var artworkTextColor4: String? = nil
    /// 动态封面的 HLS master playlist（1:1 与 3:4），来自 Apple Music 的
    /// attributes.editorialVideo。公开无签名链接，可以直接交给播放器。
    ///
    /// 只有专辑和单曲任务可能有，而且只有部分专辑有。后端是在解析之后**异步**回填
    /// 的，所以刚建的任务这两个字段是空的、过一会儿才出现（届时会推一条
    /// motion_artwork_resolved 事件）。空就当作「没有动态封面」。
    var motionArtworkURL: String? = nil
    var motionArtworkTallURL: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, input, type, storefront, title, force, status, error, genre
        case artworkURL = "artwork_url"
        case totalItems = "total_items"
        case doneItems = "done_items"
        case failedItems = "failed_items"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case artistName = "artist_name"
        case curatorName = "curator_name"
        case releaseDate = "release_date"
        case artworkBgColor = "artwork_bg_color"
        case artworkTextColor1 = "artwork_text_color1"
        case artworkTextColor2 = "artwork_text_color2"
        case artworkTextColor3 = "artwork_text_color3"
        case artworkTextColor4 = "artwork_text_color4"
        case motionArtworkURL = "motion_artwork_url"
        case motionArtworkTallURL = "motion_artwork_tall_url"
    }

    var progress: Double {
        guard totalItems > 0 else { return 0 }
        return Double(doneItems) / Double(totalItems)
    }

    /// artwork_url 是带 {w}x{h}（可能还有 {f}）占位符的模板，需要替换成具体像素尺寸才能请求到图片。
    func artworkURL(pixelSize: Int = 100) -> URL? {
        guard let artworkURL, !artworkURL.isEmpty else { return nil }
        let resolved = artworkURL
            .replacingOccurrences(of: "{w}", with: String(pixelSize))
            .replacingOccurrences(of: "{h}", with: String(pixelSize))
            .replacingOccurrences(of: "{f}", with: "jpg")
        return URL(string: resolved)
    }

    /// 后端解析完 input 后会回填 title（曲目/专辑/歌单/艺人名）；解析完成前 title 为空，此时直接显示原始链接。
    var displayName: String {
        guard let title, !title.isEmpty else { return input }
        return title
    }

    var artworkBackgroundColor: Color? { Color(hexRGB: artworkBgColor) }
    var artworkPrimaryTextColor: Color? { Color(hexRGB: artworkTextColor1) }
    var artworkSecondaryTextColor: Color? { Color(hexRGB: artworkTextColor2) }

    /// 详情快照在解析/刷新交界处可能暂时缺少展示元数据。状态与计数仍以新快照
    /// 为准，只用已经显示过的非空值补齐封面、标题和配色，避免下拉刷新让头部闪空。
    mutating func preservePresentationMetadata(from fallback: Job) {
        storefront = preferredPresentationValue(storefront, fallback: fallback.storefront)
        title = preferredPresentationValue(title, fallback: fallback.title)
        artworkURL = preferredPresentationValue(artworkURL, fallback: fallback.artworkURL)
        artistName = preferredPresentationValue(artistName, fallback: fallback.artistName)
        curatorName = preferredPresentationValue(curatorName, fallback: fallback.curatorName)
        releaseDate = preferredPresentationValue(releaseDate, fallback: fallback.releaseDate)
        genre = preferredPresentationValue(genre, fallback: fallback.genre)
        artworkBgColor = preferredPresentationValue(
            artworkBgColor,
            fallback: fallback.artworkBgColor
        )
        artworkTextColor1 = preferredPresentationValue(
            artworkTextColor1,
            fallback: fallback.artworkTextColor1
        )
        artworkTextColor2 = preferredPresentationValue(
            artworkTextColor2,
            fallback: fallback.artworkTextColor2
        )
        artworkTextColor3 = preferredPresentationValue(
            artworkTextColor3,
            fallback: fallback.artworkTextColor3
        )
        artworkTextColor4 = preferredPresentationValue(
            artworkTextColor4,
            fallback: fallback.artworkTextColor4
        )
        // 动态封面是异步回填的，刷新快照时更容易撞上「后端还没写完」的空窗；
        // 沿用已经显示过的值，避免正在播放的封面被一次刷新打回静态图。
        motionArtworkURL = preferredPresentationValue(
            motionArtworkURL,
            fallback: fallback.motionArtworkURL
        )
        motionArtworkTallURL = preferredPresentationValue(
            motionArtworkTallURL,
            fallback: fallback.motionArtworkTallURL
        )
    }

    var statusText: String {
        switch status {
        case .queued:
            "排队中"
        case .running:
            "下载中 \(doneItems)/\(totalItems)"
        case .completed:
            failedItems > 0 ? "已完成（\(failedItems) 项失败）" : "已完成"
        case .failed:
            error ?? "下载失败"
        case .cancelled:
            "已取消"
        }
    }
}

enum JobItemStatus: String, Codable {
    case queued
    case resolving
    case downloading
    case decrypting
    case remuxing
    case tagging
    case saving
    case completed
    case failed
    case skippedExisting = "skipped_existing"
    case cancelled

    var isActive: Bool {
        switch self {
        case .queued, .resolving, .downloading, .decrypting, .remuxing, .tagging, .saving:
            true
        case .completed, .failed, .skippedExisting, .cancelled:
            false
        }
    }

    var symbolName: String {
        switch self {
        case .queued:
            "clock"
        case .resolving:
            "magnifyingglass"
        case .downloading:
            "arrow.down.circle.fill"
        case .decrypting:
            "lock.open"
        case .remuxing:
            "waveform"
        case .tagging:
            "tag"
        case .saving:
            "square.and.arrow.down"
        case .completed, .skippedExisting:
            "checkmark.circle.fill"
        case .failed:
            "xmark.circle.fill"
        case .cancelled:
            "minus.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .queued:
            .secondary
        case .resolving, .downloading, .decrypting, .remuxing, .tagging, .saving:
            .blue
        case .completed, .skippedExisting:
            .green
        case .failed:
            .red
        case .cancelled:
            .secondary
        }
    }

    var text: String {
        switch self {
        case .queued:
            "排队中"
        case .resolving:
            "解析中"
        case .downloading:
            "下载中"
        case .decrypting:
            "解密中"
        case .remuxing:
            "封装中"
        case .tagging:
            "写入标签"
        case .saving:
            "保存中"
        case .completed:
            "已完成"
        case .failed:
            "失败"
        case .skippedExisting:
            "已存在，已跳过"
        case .cancelled:
            "已取消"
        }
    }
}

struct JobItem: Codable, Identifiable {
    let id: String
    let jobID: String
    let adamID: String
    let kind: String
    let index: Int
    var title: String?
    var artist: String?
    var album: String?
    /// 曲目时长（毫秒），解析集合时随标题/艺人/专辑一并从 Apple Music 目录取得，
    /// 下载前即可用。旧后端或目录缺失时为空。
    var durationMs: Int?
    var artworkURL: String?
    var status: JobItemStatus
    var progress: Double
    var codec: String?
    /// 当前尝试编码的位深，仅无损编码（如 ALAC）有值；AAC-LC 等有损编码没有逐曲清单可读，恒为空。
    var bitDepth: Int?
    /// 采样率（Hz），语义同 bitDepth。
    var sampleRate: Int?
    /// 码率（bps）；无损编码取自 HLS 分片声明的平均带宽，并非真实恒定码率。
    var bitrate: Int?
    var retryKind: String?
    var attempt: Int?
    var maxAttempts: Int?
    var statusMessage: String?
    var error: String?
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, index, title, artist, album, status, progress, codec, error
        case jobID = "job_id"
        case adamID = "adam_id"
        case artworkURL = "artwork_url"
        case durationMs = "duration_ms"
        case bitDepth = "bit_depth"
        case sampleRate = "sample_rate"
        case bitrate
        case retryKind = "retry_kind"
        case attempt
        case maxAttempts = "max_attempts"
        case statusMessage = "status_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var displayTitle: String {
        guard let title, !title.isEmpty else {
            return index > 0 ? "第 \(index) 项" : adamID
        }
        return title
    }

    var subtitle: String {
        [artist, album]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    var statusText: String {
        if status == .failed, let error, !error.isEmpty {
            return error
        }
        // 后端快照在终态仍保留最后一条阶段消息（如 "ALAC download completed"），
        // 刷新后会把本地化的「已完成」顶掉；status_message 只在活跃阶段展示。
        if status.isActive, let statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }
        return status.text
    }

    func artworkURL(pixelSize: Int = 100) -> URL? {
        guard let artworkURL, !artworkURL.isEmpty else { return nil }
        let resolved = artworkURL
            .replacingOccurrences(of: "{w}", with: String(pixelSize))
            .replacingOccurrences(of: "{h}", with: String(pixelSize))
            .replacingOccurrences(of: "{f}", with: "jpg")
        return URL(string: resolved)
    }

    /// 无损编码显示位深/采样率（如 "24bit/96kHz"）；有损编码没有逐曲清单可读位深/采样率，退而显示码率；都没有时为空。
    var qualityText: String? {
        if let bitDepth, bitDepth > 0, let sampleRate, sampleRate > 0 {
            let khz = Double(sampleRate) / 1000
            let khzText = khz.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", khz)
                : String(format: "%.1f", khz)
            return "\(bitDepth)bit/\(khzText)kHz"
        }
        if let bitrate, bitrate > 0 {
            return "\(bitrate / 1000)kbps"
        }
        return nil
    }

    mutating func preservePresentationMetadata(from fallback: JobItem) {
        title = preferredPresentationValue(title, fallback: fallback.title)
        artist = preferredPresentationValue(artist, fallback: fallback.artist)
        album = preferredPresentationValue(album, fallback: fallback.album)
        artworkURL = preferredPresentationValue(artworkURL, fallback: fallback.artworkURL)
        codec = preferredPresentationValue(codec, fallback: fallback.codec)
        bitDepth = bitDepth ?? fallback.bitDepth
        sampleRate = sampleRate ?? fallback.sampleRate
        bitrate = bitrate ?? fallback.bitrate
    }
}

/// 下载后 hook（如通知、后处理脚本）的最新执行状态快照，由后端从 hook_started/
/// hook_succeeded/hook_failed 事件推导而来。
struct HookState: Codable, Identifiable {
    let name: String
    let status: String
    var error: String?

    var id: String { name }

    var isActive: Bool { status == "running" }

    var statusText: String {
        switch status {
        case "running": "执行中"
        case "succeeded": "成功"
        case "failed": "失败"
        case "interrupted": "中断（服务重启，不会再有结果）"
        default: status
        }
    }

    var tint: Color {
        switch status {
        case "running": .blue
        case "succeeded": .green
        case "failed": .red
        default: .secondary
        }
    }

    var symbolName: String {
        switch status {
        case "running": "ellipsis.circle"
        case "succeeded": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        default: "exclamationmark.circle"
        }
    }
}

struct DownloadDetail: Codable {
    var job: Job
    var items: [JobItem]
    /// 每个已触发 hook 的最新状态；旧后端没有此字段时为 nil，等同空数组。
    var hooks: [HookState]?
    /// 生成本快照时该任务已有事件的最大 id。首连 WS 直接用它做
    /// last_event_id 续接，跳过历史回放；旧后端没有此字段时为 nil。
    var lastEventID: Int64?

    enum CodingKeys: String, CodingKey {
        case job, items, hooks
        case lastEventID = "last_event_id"
    }

    var progress: Double {
        guard !items.isEmpty else { return job.progress }
        let total = items.reduce(0) { $0 + $1.clampedProgress }
        return total / Double(items.count)
    }

    /// 合并刷新快照时保留已解析出的稳定展示信息。下载状态、进度、错误和 hook
    /// 均继续使用新快照；只有新快照缺失的媒体元数据才从当前页面补回。
    mutating func preservePresentationMetadata(from fallback: DownloadDetail) {
        job.preservePresentationMetadata(from: fallback.job)

        let fallbackItems = Dictionary(uniqueKeysWithValues: fallback.items.map { ($0.id, $0) })
        for index in items.indices {
            guard let fallbackItem = fallbackItems[items[index].id] else { continue }
            items[index].preservePresentationMetadata(from: fallbackItem)
        }
    }

    /// 把 WS 事件流里的一条事件合并进本地状态，避免轮询。
    /// item_progress 的 payload 是完整 JobItem（缺 artwork_url）；
    /// 终态由 item_completed/item_failed/item_skipped 与 job_* 事件表达。
    @discardableResult
    mutating func apply(_ event: DownloadEvent) -> Bool {
        if let lastEventID, event.id <= lastEventID {
            return false
        }
        lastEventID = event.id

        switch event.type {
        case "job_queued":
            job.status = .queued

        case "job_started", "job_recovered":
            job.status = .running

        case "job_finished":
            job.status = event.message.flatMap { JobStatus(rawValue: $0) } ?? .completed

        case "job_failed":
            job.status = .failed
            job.error = event.message

        case "job_cancelled":
            job.status = .cancelled
            job.error = event.message ?? "cancelled"

        case "item_progress":
            guard var item = event.decodeItem() else { return true }
            if item.artworkURL?.isEmpty != false {
                // 事件里去掉了封面模板，保留初始 GET 拿到的那份。
                item.artworkURL = items.first(where: { $0.id == item.id })?.artworkURL
            }
            upsert(item)

        case "item_completed":
            mutateItem(id: event.itemID) { item in
                item.status = .completed
                item.progress = 1
                item.statusMessage = nil
                item.error = nil
                if let payload = event.decodeItemCompletedPayload() {
                    item.codec = payload.codec ?? item.codec
                    item.bitDepth = payload.bitDepth ?? item.bitDepth
                    item.sampleRate = payload.sampleRate ?? item.sampleRate
                    item.bitrate = payload.bitrate ?? item.bitrate
                    // attempt/max_attempts 不再从完成事件合并：后端 payload 改为
                    // download_attempts/decrypt_attempts 两个独立字段，而 item 的
                    // attempt 状态已通过 item_progress 全量载荷保持最新。
                }
            }

        case "item_skipped":
            mutateItem(id: event.itemID) { item in
                item.status = .skippedExisting
                item.progress = 1
                item.statusMessage = nil
            }

        case "item_failed":
            mutateItem(id: event.itemID) { item in
                item.status = .failed
                item.error = event.message
            }

        case "hook_started", "hook_succeeded", "hook_failed":
            // phase 字段承载 hook 名（与 SummarizeHooks 的推导口径一致）。
            guard let name = event.phase else { return true }
            let status: String
            switch event.type {
            case "hook_succeeded": status = "succeeded"
            case "hook_failed": status = "failed"
            default: status = "running"
            }
            upsertHook(HookState(name: name, status: status, error: event.type == "hook_failed" ? event.message : nil))

        default:
            // codec_selected / 重试类事件等只影响细节文案，忽略即可。
            break
        }

        refreshCounts()
        return true
    }

    private mutating func upsert(_ item: JobItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            items.sort { $0.index < $1.index }
        }
    }

    private mutating func mutateItem(id: String?, _ transform: (inout JobItem) -> Void) {
        guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return }
        transform(&items[index])
    }

    private mutating func upsertHook(_ hook: HookState) {
        if let index = hooks?.firstIndex(where: { $0.name == hook.name }) {
            hooks?[index] = hook
        } else {
            hooks = (hooks ?? []) + [hook]
        }
    }

    /// 与后端 CountItemProgress 一致：从当前 items 重新推导任务级计数。
    private mutating func refreshCounts() {
        guard !items.isEmpty else { return }
        job.doneItems = items.filter { $0.status == .completed || $0.status == .skippedExisting }.count
        job.failedItems = items.filter { $0.status == .failed }.count
        job.totalItems = max(job.totalItems, items.count)
    }
}

private func preferredPresentationValue(_ value: String?, fallback: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return fallback
    }
    return value
}

/// 下载任务事件（WS/SSE 共用的 Event 对象）。payload 本身是 JSON 字符串，需二次解析。
struct DownloadEvent: Codable {
    let id: Int64
    let jobID: String
    let itemID: String?
    let type: String
    let phase: String?
    let message: String?
    let payload: String?

    enum CodingKeys: String, CodingKey {
        case id, type, phase, message, payload
        case jobID = "job_id"
        case itemID = "item_id"
    }

    /// `resolved_input` is only a marker. The backend persists title, artwork
    /// and item metadata before/around this event but does not include them in
    /// its payload, so the detail screen must refresh its snapshot once.
    var requiresDetailSnapshotRefresh: Bool {
        type == "resolved_input"
    }

    struct ItemCompletedPayload: Codable {
        let codec: String?
        let bitDepth: Int?
        let sampleRate: Int?
        let bitrate: Int?
        let downloadAttempts: Int?
        let decryptAttempts: Int?

        enum CodingKeys: String, CodingKey {
            case codec, bitrate
            case bitDepth = "bit_depth"
            case sampleRate = "sample_rate"
            case downloadAttempts = "download_attempts"
            case decryptAttempts = "decrypt_attempts"
        }
    }

    func decodeItem() -> JobItem? {
        guard let data = payload?.data(using: .utf8) else { return nil }
        return try? DownloadsAPI.decodeJobItem(from: data)
    }

    func decodeItemCompletedPayload() -> ItemCompletedPayload? {
        guard let data = payload?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ItemCompletedPayload.self, from: data)
    }
}

/// GET /downloads 快照：任务列表 + 全局事件游标，用于续接总览级 SSE/WS 推送。
struct DownloadsSnapshot: Codable {
    var downloads: [Job]
    var lastEventID: Int64

    enum CodingKeys: String, CodingKey {
        case downloads
        case lastEventID = "last_event_id"
    }
}

/// 总览级 SSE/WS 推送（/downloads/events(/ws)）的一条消息：任务新建/变化，或被删除。
struct DownloadFeedMessage: Codable {
    let type: String
    let job: Job?
    let jobID: String?
    /// download_deleted 不带此值（删除未持久化），不应据此推进续接游标。
    let eventID: Int64?

    enum CodingKeys: String, CodingKey {
        case type, job
        case jobID = "job_id"
        case eventID = "event_id"
    }
}

struct DownloadCreateRequest: Encodable {
    let urls: [String]
    let overrides: DownloadCreateOverrides

    /// forceOverwrite 传 nil 表示「不覆盖这一项」，请求里就不会出现
    /// overrides.force_overwrite，后端于是沿用运行时配置 download.force_overwrite。
    /// 之前它是非可选的，每次提交都会发一个 false 出去，把全局设置顶掉——
    /// 表现就是「总配置里开了覆盖却不生效，只有下载时勾选才有用」。
    init(input: String, forceOverwrite: Bool?, mediaUserToken: String?) {
        urls = [input]
        overrides = DownloadCreateOverrides(
            forceOverwrite: forceOverwrite,
            mediaUserToken: mediaUserToken?.isEmpty == false ? mediaUserToken : nil
        )
    }
}

struct DownloadCreateOverrides: Encodable {
    let forceOverwrite: Bool?
    let mediaUserToken: String?

    enum CodingKeys: String, CodingKey {
        case forceOverwrite = "force_overwrite"
        case mediaUserToken = "media_user_token"
    }
}

struct DownloadSubmitResponse: Decodable {
    let accepted: Int
    let rejected: Int
    let results: [DownloadSubmitResult]

    var firstAcceptedJobID: String? {
        results.first { $0.status == "accepted" }?.job?.id
    }

    var firstExistingJobID: String? {
        results.compactMap(\.existingJobID).first
    }

    var firstError: String? {
        results.compactMap(\.error).first
    }
}

struct DownloadSubmitResult: Decodable {
    let url: String
    let status: String
    let job: Job?
    let existingJobID: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case url, status, job, error
        case existingJobID = "existing_job_id"
    }
}

enum DownloadsAPIError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "后端地址无效，请到「配置」页检查"
        case .invalidResponse:
            "服务器返回了无法解析的数据"
        case let .server(status, message):
            message ?? "服务器错误 (\(status))"
        }
    }
}

enum DownloadsAPI {
    private static let baseURLKey = "backendBaseURL"
    /// 公开部署的测试后端。它在网关（oauth2-proxy）后面，所有 /api 请求都需要
    /// 「通过 Apple 登录」拿到的 Bearer 令牌，见 `AppleAuth.swift`。
    /// 仍然可以在「配置 → 调试」里改成别的地址。
    static let defaultBaseURLString = "https://backend-dev-amdl.lyjw131.com"
    static let appGroupIdentifier = "group.com.lyjw131.amdl.amdl-ios"
    private static let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)

    /// 后端根地址，可在「配置」页修改；主 App 和分享扩展共用这个值。
    static var baseURLString: String {
        get {
            if let shared = sharedDefaults?.string(forKey: baseURLKey), !shared.isEmpty {
                return shared
            }
            // 早期版本把地址存在 standard defaults 里，这里搬进 App Group 让
            // 分享扩展也能读到。不再改写具体地址：内置默认值已移除，用户填什么用什么。
            if let legacy = UserDefaults.standard.string(forKey: baseURLKey), !legacy.isEmpty {
                sharedDefaults?.set(legacy, forKey: baseURLKey)
                return legacy
            }
            return defaultBaseURLString
        }
        set {
            sharedDefaults?.set(newValue, forKey: baseURLKey)
            UserDefaults.standard.set(newValue, forKey: baseURLKey)
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = fractionalFormatter.date(from: string) ?? formatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析日期: \(string)")
        }
        return decoder
    }()

    static func listDownloads(limit: Int = 50) async throws -> DownloadsSnapshot {
        let url = try makeURL(path: "/api/v1/downloads", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ])

        let data = try await fetchData(from: url)
        return try decoder.decode(DownloadsSnapshot.self, from: data)
    }

    static func getDownload(id: String) async throws -> DownloadDetail {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = try makeURL(path: "/api/v1/downloads/\(encodedID)")
        let data = try await fetchData(from: url)
        return try decodeDownloadDetail(from: data)
    }

    static func createDownload(
        input: String,
        forceOverwrite: Bool? = nil,
        mediaUserToken: String?
    ) async throws -> DownloadSubmitResponse {
        let url = try makeURL(path: "/api/v1/downloads")
        var request = URLRequest(authorizedURL: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DownloadCreateRequest(
                input: input,
                forceOverwrite: forceOverwrite,
                mediaUserToken: mediaUserToken
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadsAPIError.invalidResponse
        }
        if httpResponse.statusCode == 202 || httpResponse.statusCode == 422,
           let result = try? decoder.decode(DownloadSubmitResponse.self, from: data) {
            return result
        }
        let backendError = try? decoder.decode(ErrorResponse.self, from: data)
        throw DownloadsAPIError.server(
            status: httpResponse.statusCode,
            message: backendError?.message ?? backendError?.error
        )
    }

    static func decodeDownloadDetail(from data: Data) throws -> DownloadDetail {
        try decoder.decode(DownloadDetail.self, from: data)
    }

    static func decodeJobItem(from data: Data) throws -> JobItem {
        try decoder.decode(JobItem.self, from: data)
    }

    static func decodeEvent(from text: String) -> DownloadEvent? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? decoder.decode(DownloadEvent.self, from: data)
    }

    static func decodeFeedMessage(from text: String) -> DownloadFeedMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? decoder.decode(DownloadFeedMessage.self, from: data)
    }

    /// 任务事件流的 WebSocket 端点；断线重连时带上 last_event_id 只接收更新的事件。
    static func eventsWebSocketURL(jobID: String, lastEventID: Int64 = 0) throws -> URL {
        // 地址为空时 URLComponents 仍会构造成功，只是没有 scheme/host，因此显式
        // 排除空串，让未配置地址走到 invalidBaseURL 的提示上。
        guard !baseURLString.isEmpty, var components = URLComponents(string: baseURLString) else {
            throw DownloadsAPIError.invalidBaseURL
        }

        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        let encodedID = jobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobID
        components.path = "/api/v1/downloads/\(encodedID)/events/ws"
        if lastEventID > 0 {
            components.queryItems = [URLQueryItem(name: "last_event_id", value: String(lastEventID))]
        }

        guard let url = components.url else {
            throw DownloadsAPIError.invalidBaseURL
        }
        return url
    }

    /// 总览级下载列表变化的 WebSocket 端点；断线重连时带上 last_event_id 只接收更新的变化。
    static func downloadsFeedWebSocketURL(lastEventID: Int64 = 0) throws -> URL {
        // 地址为空时 URLComponents 仍会构造成功，只是没有 scheme/host，因此显式
        // 排除空串，让未配置地址走到 invalidBaseURL 的提示上。
        guard !baseURLString.isEmpty, var components = URLComponents(string: baseURLString) else {
            throw DownloadsAPIError.invalidBaseURL
        }

        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path = "/api/v1/downloads/events/ws"
        if lastEventID > 0 {
            components.queryItems = [URLQueryItem(name: "last_event_id", value: String(lastEventID))]
        }

        guard let url = components.url else {
            throw DownloadsAPIError.invalidBaseURL
        }
        return url
    }

    private static func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        // 地址为空时 URLComponents 仍会构造成功，只是没有 scheme/host，因此显式
        // 排除空串，让未配置地址走到 invalidBaseURL 的提示上。
        guard !baseURLString.isEmpty, var components = URLComponents(string: baseURLString) else {
            throw DownloadsAPIError.invalidBaseURL
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw DownloadsAPIError.invalidBaseURL
        }
        return url
    }

    private static func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(authorizedURL: url))

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadsAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let message = try? decoder.decode(ErrorResponse.self, from: data).message
            throw DownloadsAPIError.server(status: httpResponse.statusCode, message: message)
        }

        return data
    }
}

private struct ErrorResponse: Codable {
    let error: String
    let message: String?
}
