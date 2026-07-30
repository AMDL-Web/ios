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
    /// 该艺人在 music.apple.com 上的主页，后端解析时从 Apple 的 artist 资源一并
    /// 取回。只有单曲/专辑/艺人任务有；歌单和电台那行是策展人不是艺人，没有。
    /// 这个字段出现之前解析过的任务也是空的 —— 见 AppleMusicLinks 的退路。
    var artistURL: String? = nil
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
    /// 每个动态变体自带一套调色板（取自它自己的 previewFrame），**不是**静态封面
    /// 那套。展示哪个资产就用哪套，混用会得到深底深字。
    var motionArtworkBgColor: String? = nil
    var motionArtworkTextColor1: String? = nil
    var motionArtworkTextColor2: String? = nil
    var motionArtworkTextColor3: String? = nil
    var motionArtworkTextColor4: String? = nil
    var motionArtworkTallBgColor: String? = nil
    var motionArtworkTallTextColor1: String? = nil
    var motionArtworkTallTextColor2: String? = nil
    var motionArtworkTallTextColor3: String? = nil
    var motionArtworkTallTextColor4: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, input, type, storefront, title, force, status, error, genre
        case artworkURL = "artwork_url"
        case totalItems = "total_items"
        case doneItems = "done_items"
        case failedItems = "failed_items"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case artistName = "artist_name"
        case artistURL = "artist_url"
        case curatorName = "curator_name"
        case releaseDate = "release_date"
        case artworkBgColor = "artwork_bg_color"
        case artworkTextColor1 = "artwork_text_color1"
        case artworkTextColor2 = "artwork_text_color2"
        case artworkTextColor3 = "artwork_text_color3"
        case artworkTextColor4 = "artwork_text_color4"
        case motionArtworkURL = "motion_artwork_url"
        case motionArtworkTallURL = "motion_artwork_tall_url"
        case motionArtworkBgColor = "motion_artwork_bg_color"
        case motionArtworkTextColor1 = "motion_artwork_text_color1"
        case motionArtworkTextColor2 = "motion_artwork_text_color2"
        case motionArtworkTextColor3 = "motion_artwork_text_color3"
        case motionArtworkTextColor4 = "motion_artwork_text_color4"
        case motionArtworkTallBgColor = "motion_artwork_tall_bg_color"
        case motionArtworkTallTextColor1 = "motion_artwork_tall_text_color1"
        case motionArtworkTallTextColor2 = "motion_artwork_tall_text_color2"
        case motionArtworkTallTextColor3 = "motion_artwork_tall_text_color3"
        case motionArtworkTallTextColor4 = "motion_artwork_tall_text_color4"
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
        artistURL = preferredPresentationValue(artistURL, fallback: fallback.artistURL)
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
        motionArtworkBgColor = preferredPresentationValue(motionArtworkBgColor, fallback: fallback.motionArtworkBgColor)
        motionArtworkTextColor1 = preferredPresentationValue(motionArtworkTextColor1, fallback: fallback.motionArtworkTextColor1)
        motionArtworkTextColor2 = preferredPresentationValue(motionArtworkTextColor2, fallback: fallback.motionArtworkTextColor2)
        motionArtworkTextColor3 = preferredPresentationValue(motionArtworkTextColor3, fallback: fallback.motionArtworkTextColor3)
        motionArtworkTextColor4 = preferredPresentationValue(motionArtworkTextColor4, fallback: fallback.motionArtworkTextColor4)
        motionArtworkTallBgColor = preferredPresentationValue(motionArtworkTallBgColor, fallback: fallback.motionArtworkTallBgColor)
        motionArtworkTallTextColor1 = preferredPresentationValue(motionArtworkTallTextColor1, fallback: fallback.motionArtworkTallTextColor1)
        motionArtworkTallTextColor2 = preferredPresentationValue(motionArtworkTallTextColor2, fallback: fallback.motionArtworkTallTextColor2)
        motionArtworkTallTextColor3 = preferredPresentationValue(motionArtworkTallTextColor3, fallback: fallback.motionArtworkTallTextColor3)
        motionArtworkTallTextColor4 = preferredPresentationValue(motionArtworkTallTextColor4, fallback: fallback.motionArtworkTallTextColor4)
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
    case waitingDownload = "waiting_download"
    case downloading
    case waitingDecrypt = "waiting_decrypt"
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
        case .queued, .resolving, .waitingDownload, .downloading,
             .waitingDecrypt, .decrypting, .remuxing, .tagging, .saving:
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
        case .waitingDownload, .waitingDecrypt:
            "hourglass"
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
        case .waitingDownload, .waitingDecrypt:
            .secondary
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
        case .waitingDownload:
            "等待下载"
        case .downloading:
            "下载中"
        case .waitingDecrypt:
            "等待解密"
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

/// 后端 `JobItem.progress` 的逐阶段拆分。取代了此前那个跨整条流水线的
/// 单一 0..1 总进度：下载和解密曾被压进同一根轴的两段子区间（5–55% 与
/// 55–90%），原子阶段则只是轴上的固定点 —— 0.97 从来不是「标签写了 97%」，
/// 只是「开始写标签」。
///
/// 后端现在不再给总进度，`fraction` 里的加权纯粹是本客户端的展示决定。
struct ItemProgress: Codable, Equatable, Sendable {
    /// 加密媒体已传输的比例。传输不可测量时（响应没有 Content-Length）恒为 0，
    /// 所以 0 配上 status=downloading 意思是「正在下载，大小未知」，不是「一个字节都没下」。
    var download: Double = 0
    /// 已送进解密器的字节比例。aac-lc 走的是一次性解密，中间没有可报的计数，
    /// 那条路径上它会在封装边界从 0 直接跳到 1。
    var decrypt: Double = 0
    /// 目录元数据已取得。
    var resolved: Bool = false
    /// 解密流已展平成 progressive MP4。
    var remuxed: Bool = false
    /// 完整性校验已执行且通过。后端 `download.check_integrity` 关闭时同样为 false，
    /// 所以 false 只表示「未校验」，绝不表示「文件损坏」—— 校验失败会直接让整项失败。
    /// 这是已完成项目唯一可以合理留 false 的标志。
    var verified: Bool = false
    /// 元数据（以及按配置的封面／歌词）已写入文件。
    var tagged: Bool = false
    /// 成品文件已移动到最终路径。这是流水线最后一步，为真即整项完成。
    var saved: Bool = false

    /// 契约里这些字段都是必填的，但仍然逐个容错解码：后端和 App 不是同时发版的，
    /// 缺一个字段应该退化成「那个阶段没完成」，而不是让整个 JobItem 解不出来。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        download = try container.decodeIfPresent(Double.self, forKey: .download) ?? 0
        decrypt = try container.decodeIfPresent(Double.self, forKey: .decrypt) ?? 0
        resolved = try container.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        remuxed = try container.decodeIfPresent(Bool.self, forKey: .remuxed) ?? false
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        tagged = try container.decodeIfPresent(Bool.self, forKey: .tagged) ?? false
        saved = try container.decodeIfPresent(Bool.self, forKey: .saved) ?? false
    }

    init() {}
}

extension ItemProgress {
    /// 各阶段在单根进度条上占的比重，合计为 1。
    ///
    /// 大体沿用旧后端那套轴的手感（下载占大头，解密次之，收尾几步各占一点），
    /// 但按实测把两者的比例调开了：解密比下载快，旧的 50% / 35% 让进度条在解密
    /// 阶段走得明显偏快。这里收到 56% / 26%，收尾阶段相应各分到一点。
    private enum Weight {
        static let resolved = 0.04
        static let download = 0.56
        static let decrypt = 0.26
        static let remuxed = 0.06
        static let verified = 0.03
        static let tagged = 0.03
        static let saved = 0.02
    }

    /// 折算成单根进度条用的 0..1。
    var fraction: Double {
        // saved 是流水线最后一步，为真即全部走完。直接短路还顺带吸收掉
        // check_integrity 关闭时 verified 永远为 false 留下的那 3%。
        if saved { return 1 }
        var value = 0.0
        if resolved { value += Weight.resolved }
        value += Weight.download * min(max(download, 0), 1)
        value += Weight.decrypt * min(max(decrypt, 0), 1)
        if remuxed { value += Weight.remuxed }
        if verified { value += Weight.verified }
        if tagged { value += Weight.tagged }
        return min(max(value, 0), 1)
    }

    /// 整项完成时的形态：两个 meter 拉满，除 verified 外的阶段全部置位。
    /// verified 保持原样 —— 后端在 check_integrity 关闭时本来就不会置它，
    /// 这里替它置上就是在编造历史。
    mutating func markCompleted() {
        download = 1
        decrypt = 1
        resolved = true
        remuxed = true
        tagged = true
        saved = true
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
    var progress: ItemProgress
    var codec: String?
    /// 当前尝试编码的位深，仅无损编码（如 ALAC）有值；AAC-LC 等有损编码没有逐曲清单可读，恒为空。
    var bitDepth: Int?
    /// 采样率（Hz），语义同 bitDepth。
    var sampleRate: Int?
    /// 码率（bps）；无损编码取自 HLS 分片声明的平均带宽，并非真实恒定码率。
    var bitrate: Int?
    /// 成品文件字节数，落盘（completed）或发现已存在（skipped_existing）后才有值；
    /// 在此之前、旧后端、以及 stat 失败时为空。重试会把它清回 0。
    var fileSize: Int64?
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
        case fileSize = "file_size"
        case retryKind = "retry_kind"
        case attempt
        case maxAttempts = "max_attempts"
        case statusMessage = "status_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// 单根进度条用的 0..1。终态直接返回 1：`skipped_existing` 的文件本来就在盘上，
    /// 一个阶段都没跑，拆分里全是零值 —— 判断是否完成看 status，不看 progress。
    var clampedProgress: Double {
        switch status {
        case .completed, .skippedExisting:
            1
        default:
            progress.fraction
        }
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
        if status == .waitingDownload || status == .waitingDecrypt {
            return status.text
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
                item.progress.markCompleted()
                item.statusMessage = nil
                item.error = nil
                if let payload = event.decodeItemCompletedPayload() {
                    item.codec = payload.codec ?? item.codec
                    item.bitDepth = payload.bitDepth ?? item.bitDepth
                    item.sampleRate = payload.sampleRate ?? item.sampleRate
                    item.bitrate = payload.bitrate ?? item.bitrate
                    // 落盘大小只在这条事件里第一次出现（item_progress 期间文件还没写完）。
                    item.fileSize = payload.fileSize ?? item.fileSize
                    // attempt/max_attempts 不再从完成事件合并：后端 payload 改为
                    // download_attempts/decrypt_attempts 两个独立字段，而 item 的
                    // attempt 状态已通过 item_progress 全量载荷保持最新。
                }
            }

        case "item_skipped":
            mutateItem(id: event.itemID) { item in
                item.status = .skippedExisting
                // 拆分保持零值，跟后端一致：跳过的项目一个阶段都没跑。
                // 进度条由 clampedProgress 按 status 判定为满格。
                item.statusMessage = nil
                if let fileSize = event.decodeItemSkippedPayload()?.fileSize {
                    item.fileSize = fileSize
                }
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
    /// 这些事件改的是任务行本身，光靠事件负载补不齐，必须重新拉一次快照。
    ///
    /// motion_artwork_resolved 尤其容易漏：它落在 apply 的 default 分支里被忽略，
    /// 若不在这里点名，详情页开着的时候动态封面到了也不会替换——只有退出重进才看
    /// 得到。
    var requiresDetailSnapshotRefresh: Bool {
        type == "resolved_input" || type == "motion_artwork_resolved"
    }

    struct ItemCompletedPayload: Codable {
        let codec: String?
        let bitDepth: Int?
        let sampleRate: Int?
        let bitrate: Int?
        let fileSize: Int64?
        let downloadAttempts: Int?
        let decryptAttempts: Int?

        enum CodingKeys: String, CodingKey {
            case codec, bitrate
            case bitDepth = "bit_depth"
            case sampleRate = "sample_rate"
            case fileSize = "file_size"
            case downloadAttempts = "download_attempts"
            case decryptAttempts = "decrypt_attempts"
        }
    }

    /// item_skipped 的 payload 同样是整条 item 快照，只取落盘大小即可。
    struct ItemSkippedPayload: Codable {
        let fileSize: Int64?

        enum CodingKeys: String, CodingKey {
            case fileSize = "file_size"
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

    func decodeItemSkippedPayload() -> ItemSkippedPayload? {
        guard let data = payload?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ItemSkippedPayload.self, from: data)
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
    /// `code` 是错误体里那个机器可读的值（`/api/v1/*` 放在 `error` 字段，
    /// `/api/gw/*` 放在 `code` 字段）。**不要直接拿它当文案** —— 它可能是
    /// `pending_approval` 这种码，也可能是 `sql: no rows in result set` 这种
    /// 后端漏出来的原始 SQL 错误。它存在是为了让调用方能按码分支，
    /// 见 `JobActionError.mapping`。
    case server(status: Int, code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "后端地址无效，请到「配置」页检查"
        case .invalidResponse:
            "服务器返回了无法解析的数据"
        case let .server(status, _, message):
            message ?? "服务器错误 (\(status))"
        }
    }
}

enum DownloadsAPI {
    /// 生产部署的门户地址（`amdl-portal`）。
    ///
    /// 旧值是 `backend-dev-amdl.example.com`，那是 oauth2-proxy 直接挡在
    /// `amdl-backend` 前面的那条链路。现在中间站着门户：它是 OIDC RP，管会话、任务
    /// 归属和配额，`/api/v1/*` 是它对后端的镜像（形状逐字节兼容，所以下面那些
    /// Codable 结构一个都不用改），`/api/gw/*` 是它自己的接口。
    ///
    /// 所有 /api 请求都要带门户签发的 Bearer 令牌，见 `PortalAuth.swift`。
    /// 仍然可以在「配置 → 调试」里改成别的地址。
    ///
    /// 具体的值和存取都在 `BackendEndpoint` 里 —— 门户是唯一的源站，所以全 App
    /// 只有那一个可配置的主机地址，这里只是它在下载 API 这一侧的名字。
    static let defaultBaseURLString = BackendEndpoint.defaultBaseURLString
    static let appGroupIdentifier = BackendEndpoint.appGroupIdentifier

    /// 后端根地址，可在「配置」页修改；主 App、分享扩展和实时活动网关共用这个值。
    static var baseURLString: String {
        get { BackendEndpoint.baseURLString }
        set { BackendEndpoint.baseURLString = newValue }
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DownloadCreateRequest(
                input: input,
                forceOverwrite: forceOverwrite,
                mediaUserToken: mediaUserToken
            )
        )

        let (data, httpResponse) = try await PortalHTTP.send(request)
        // 202 和 422 都要解 body：**422 才是配额被拒时唯一带着逐条原因的响应**。
        // 门户把每个 URL 的拒绝理由塞在 `results[].status/error` 里，整批被拒时
        // 它必须答 422 而不是 4xx 里的别的码——因为这里只对这两个码解码，别的码
        // 会把逐条理由整个丢掉，只剩一句干巴巴的错误。改这一行前先读
        // amdl-portal DESIGN.md §13.19。
        if httpResponse.statusCode == 202 || httpResponse.statusCode == 422,
           let result = try? decoder.decode(DownloadSubmitResponse.self, from: data) {
            return result
        }
        throw serverError(status: httpResponse.statusCode, data: data)
    }

    /// `POST /api/v1/downloads/{id}/cancel` → 200 `{"status":"cancelled"}`。
    ///
    /// 对终态任务同样答 200 且什么都不做，所以这里不会因为「任务刚好跑完了」而报错。
    /// 唯一的意外是任务不存在：后端那个 handler 把所有错误都写成 500
    /// （`server.go:608-614`），由 `JobActionError.mapping` 兜住。
    static func cancelDownload(id: String) async throws {
        try await act(id: id, path: "/cancel", method: "POST", expecting: 200)
    }

    /// `POST /api/v1/downloads/{id}/retry` → 202 `{"status":"queued"}`。
    ///
    /// **只收 failed 的任务**，其余一律 409（含 cancelled）。响应体里没有任务对象，
    /// 任务 id 不变，新状态靠事件流或重新拉快照。
    static func retryDownload(id: String) async throws {
        try await act(id: id, path: "/retry", method: "POST", expecting: 202)
    }

    /// `DELETE /api/v1/downloads/{id}` → 200 `{"status":"deleted"}`。终态任务才行。
    static func deleteDownload(id: String) async throws {
        try await act(id: id, path: "", method: "DELETE", expecting: 200)
    }

    private static func act(id: String, path: String, method: String, expecting: Int) async throws {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = try makeURL(path: "/api/v1/downloads/\(encodedID)\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = method

        let (data, httpResponse) = try await PortalHTTP.send(request)
        guard httpResponse.statusCode == expecting else {
            throw serverError(status: httpResponse.statusCode, data: data)
        }
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

    /// 通过 `PortalHTTP` 而不是 `URLSession.shared` 直接发：那一层负责在发之前续
    /// 快过期的 access token，并在 401 之后刷新一次、重试一次。它还会把 403 的
    /// `pending_approval` / `suspended` 翻成人话抛出来。
    private static func fetchData(from url: URL) async throws -> Data {
        let (data, httpResponse) = try await PortalHTTP.send(URLRequest(url: url))

        guard httpResponse.statusCode == 200 else {
            throw serverError(status: httpResponse.statusCode, data: data)
        }

        return data
    }

    /// 把镜像面的错误体翻成一个能给用户看的错误。
    ///
    /// `/api/v1/*` 的错误保持 amdl-backend 的 `{"error":...}` 形状，所以
    /// `pending_approval` 是从 `error` 字段里读出来的，不是 problem+json 的 `code`。
    /// 两边的值域是同一张表（DESIGN.md §6.3），一个客户端只需要一份码表。
    static func serverError(status: Int, data: Data) -> Error {
        let body = PortalErrorBody.decode(from: data)
        if let mapped = body?.authError(status: status) {
            return mapped
        }
        return DownloadsAPIError.server(
            status: status,
            code: body?.resolvedCode,
            message: body?.resolvedMessage
        )
    }
}
