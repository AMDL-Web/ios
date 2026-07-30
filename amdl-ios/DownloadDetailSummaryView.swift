//
//  DownloadDetailSummaryView.swift
//  amdl-ios
//

import SwiftUI

struct DownloadSongDetailContent: View {
    let job: Job?
    let items: [JobItem]
    let progress: Double
    let errorMessage: String?
    let palette: DownloadDetailPalette?
    @Binding var presentedQualityDetails: AudioQualityPresentation.Details?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                    }

                    if let job {
                        DownloadDetailSummaryView(
                            job: job,
                            items: items,
                            progress: progress,
                            albumTracksOmitSubtitles: false,
                            palette: palette,
                            presentedQualityDetails: $presentedQualityDetails
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct DownloadDetailSummaryView: View {
    let job: Job
    let items: [JobItem]
    let progress: Double
    let albumTracksOmitSubtitles: Bool
    let palette: DownloadDetailPalette?
    @Binding var presentedQualityDetails: AudioQualityPresentation.Details?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL

    private static let artistLineColor = Color(red: 0.98, green: 0.137, blue: 0.231)

    private var headlineSubtitle: String? {
        switch job.type {
        case .artist:
            nil
        case .playlist, .station:
            nonempty(job.curatorName)
        case .song:
            nonempty(job.artistName) ?? nonempty(items.first?.artist)
        case .album:
            nonempty(job.artistName) ?? derivedAlbumArtistName
        }
    }

    private var derivedAlbumArtistName: String? {
        let artists = items.compactMap { nonempty($0.artist) }
        guard !artists.isEmpty else { return nil }
        return Set(artists).count == 1 ? artists[0] : "群星"
    }

    private var captionSegments: [CaptionSegment] {
        var segments: [CaptionSegment] = []
        if let genre = nonempty(job.genre) {
            segments.append(.text(id: "genre", value: genre))
        }
        if let year = releaseYear {
            segments.append(.text(id: "year", value: "\(year)年"))
        }
        if job.type == .song || job.type == .album {
            segments.append(contentsOf: AudioQualityPresentation.badges(for: items).map {
                .badge($0)
            })
        }
        if let storefront = nonempty(job.storefront) {
            segments.append(.text(id: "storefront", value: storefront.uppercased()))
        }
        return segments
    }

    private var releaseYear: String? {
        guard let releaseDate = job.releaseDate, releaseDate.count >= 4 else { return nil }
        let year = String(releaseDate.prefix(4))
        return year.allSatisfy(\.isNumber) ? year : nil
    }

    private var barProgress: Double {
        job.status == .completed ? 1 : progress
    }

    var body: some View {
        VStack(spacing: 12) {
            JobArtworkView(job: job, pixelSize: JobArtworkLoader.heroPixelSize)
                .aspectRatio(1, contentMode: .fit)
                // 有动态封面的专辑在静态封面之上淡入一层循环视频；没有的话这一层
                // 什么都不画。放在 clipShape 之前，圆角同样裁到视频上。
                .overlay {
                    MotionArtworkView(job: job)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // 半透明细描边。封面边缘那一圈像素常常和背景同色（背景本来就是从
                // 封面取的），只靠投影总有一小段边化在底色里。描边取调色板的主文字
                // 色——它对背景的对比度是有保证的，浅底出深边、深底出浅边，比写死
                // 白色稳。宽度按屏幕像素算，永远是实打实的一物理像素。
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            (palette?.primaryText ?? Color.primary).opacity(0.15),
                            lineWidth: 1 / displayScale
                        )
                }
                // Apple Music 的封面不是直接贴在底色上的：一层扩散开的环境影把它
                // 从背景里托起来，再加一层贴边的接触影收住轮廓。
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
                .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
                .padding(.horizontal, 32.5)
                .padding(.bottom, 11.5)

            VStack(spacing: 2) {
                titleLabel

                if let headlineSubtitle {
                    subtitleLabel(headlineSubtitle)
                }

                JobCaptionRow(
                    job: job,
                    items: items,
                    color: palette?.tertiaryText ?? Color.secondary,
                    presentedQualityDetails: $presentedQualityDetails
                )
                .padding(.top, 2.667)
            }

            VStack(spacing: 6) {
                ThinProgressBar(
                    progress: barProgress,
                    tint: progressBarTint,
                    height: 5
                )

                HStack {
                    if job.type == .song {
                        Text(SongDetailPresentation.statusText(job: job, item: items.first))
                    } else {
                        Text("已完成 \(job.doneItems)/\(job.totalItems)")
                    }
                    Spacer()
                    Text(barProgress, format: .percent.precision(.fractionLength(0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette?.secondaryText ?? Color.secondary)

            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            if job.status == .failed,
               let error = (job.type == .song ? items.first?.error : nil) ?? job.error,
               !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 30.5)
        .padding(.bottom, albumTracksOmitSubtitles ? 28.167 : 29.5)
    }

    /// 标题点进 Apple Music 的专辑/单曲页。`input` 不是链接时保持纯文本，不给一个
    /// 点了没反应的手势。
    @ViewBuilder
    private var titleLabel: some View {
        let title = Text(job.displayName)
            .font(.title2.bold())
            .foregroundStyle(palette?.primaryText ?? Color.primary)
            .multilineTextAlignment(.center)
            // 元数据回来前 displayName 是原始 URL。链接很长时固定一行并在尾部
            // 省略；真正的曲目/专辑标题仍保留原来的多行排版。
            .lineLimit(nonempty(job.title) == nil ? 1 : nil)
            .truncationMode(.tail)

        if let url = AppleMusicLinks.collectionURL(for: job) {
            Button {
                openURL(url)
            } label: {
                title.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("在 Apple Music 中打开")
        } else {
            title
        }
    }

    /// 单曲/专辑的副标题是艺人名，点它去艺人页；歌单和电台那一行是策展人，没有对应
    /// 页面，保持纯文本。占位艺人（群星 / Various Artists）也走纯文本这一支——
    /// `artistDestination` 对它返回 nil，见 `AppleMusicLinks.isPlaceholderArtistName`。
    @ViewBuilder
    private func subtitleLabel(_ text: String) -> some View {
        let subtitle = Text(text)
            .font(.title3)
            .foregroundStyle(palette?.secondaryText ?? Self.artistLineColor)
            .multilineTextAlignment(.center)
            .padding(.top, 1.5)

        if AppleMusicLinks.canOpenArtistPage(for: job),
           let url = AppleMusicLinks.artistDestination(for: job, name: text) {
            Button {
                openURL(url)
            } label: {
                subtitle.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("在 Apple Music 中打开艺人页")
        } else {
            subtitle
        }
    }

    @ViewBuilder
    private func caption(_ segment: CaptionSegment) -> some View {
        switch segment {
        case .text(_, let text):
            Text(text)
        case .badge(let badge):
            Button {
                presentedQualityDetails = AudioQualityPresentation.details(for: items)
            } label: {
                QualityBadgeView(badge: badge)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(badge.accessibilityLabel)，查看音质详情")
            .accessibilityHint("轻点查看位深度、采样率和码率")
        }
    }

    private var progressBarTint: Color {
        switch job.status {
        case .failed:
            .red
        case .cancelled:
            palette?.tertiaryText ?? Color.secondary
        default:
            palette?.primaryText ?? job.type.tint
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct DownloadTaskSpeedView: View {
    let speed: TaskSpeedPresentation

    var body: some View {
        NavigationStack {
            ScrollView {
                TaskSpeedReadout(speed: speed, color: .secondary)
                    .padding(20)
            }
            .navigationTitle("实时速度")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private struct TaskSpeedReadout: View {
    let speed: TaskSpeedPresentation
    let color: Color

    private let downloadColor = Color.blue
    private let decryptColor = Color.orange

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                speedMetric(
                    title: "下载",
                    value: TransferSpeedFormat.string(
                        bytesPerSecond: speed.downloadBytesPerSecond
                    ),
                    countLabel: "正在下载曲目数",
                    count: speed.downloadingItemCount,
                    systemImage: "arrow.down",
                    tint: downloadColor
                )

                Divider()
                    .frame(height: 36)

                speedMetric(
                    title: "解密",
                    value: TransferSpeedFormat.string(
                        bytesPerSecond: speed.decryptBytesPerSecond
                    ),
                    countLabel: "正在解密曲目数",
                    count: speed.decryptingItemCount,
                    systemImage: "lock.open",
                    tint: decryptColor
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近速度变化")
                        .font(.caption)
                        .fontWeight(.medium)

                    Spacer()

                    Text("MB/s")
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(color)

                SWTaskSpeedLineChart(
                    points: speed.history,
                    downloadColor: downloadColor,
                    decryptColor: decryptColor,
                    axisColor: color
                )
                    .frame(height: 190)
                    .accessibilityLabel("下载与解密速度折线趋势")
                    .accessibilityValue(
                        "下载 \(TransferSpeedFormat.string(bytesPerSecond: speed.downloadBytesPerSecond))，"
                            + "解密 \(TransferSpeedFormat.string(bytesPerSecond: speed.decryptBytesPerSecond))"
                    )
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(color)
    }

    private func speedMetric(
        title: String,
        value: String,
        countLabel: String,
        count: Int,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.bold())
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.12), in: Circle())

                Text(title)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: true, vertical: false)

                Text(value)
                    .fontWeight(.semibold)
                    .contentTransition(.numericText())
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.75)

            HStack(spacing: 4) {
                Text(countLabel)
                Text(count, format: .number)
                    .fontWeight(.semibold)
                    .contentTransition(.numericText())
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)速度 \(value)，\(countLabel) \(count)")
    }
}

/// 取自 ShipSwift 多序列折线图配方的紧凑任务趋势版本：下载和解密共用纵轴，
/// 分别使用蓝、橙两条折线展示最近一段时间的速度变化。
private struct SWTaskSpeedLineChart: View {
    let points: [TaskSpeedPoint]
    let downloadColor: Color
    let decryptColor: Color
    let axisColor: Color

    private var maximumMBps: Double {
        let largest = points.reduce(0.0) {
            max(
                $0,
                max(
                    $1.downloadBytesPerSecond / 1_000_000,
                    $1.decryptBytesPerSecond / 1_000_000
                )
            )
        }
        guard largest > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(largest)))
        let normalized = largest / magnitude
        let rounded: Double
        switch normalized {
        case ...1:
            rounded = 1
        case ...2:
            rounded = 2
        case ...5:
            rounded = 5
        default:
            rounded = 10
        }
        return rounded * magnitude
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(axisLabel(maximumMBps))
                Spacer()
                Text(axisLabel(maximumMBps / 2))
                Spacer()
                Text("0.0")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(axisColor.opacity(0.8))
            .frame(width: 38)

            Canvas { context, size in
                for fraction in [0.0, 0.5, 1.0] {
                    let y = size.height * (1 - fraction)
                    var gridLine = Path()
                    gridLine.move(to: CGPoint(x: 0, y: y))
                    gridLine.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(
                        gridLine,
                        with: .color(axisColor.opacity(0.14)),
                        lineWidth: 0.5
                    )
                }

                guard !points.isEmpty else { return }
                drawLine(
                    values: points.map(\.downloadBytesPerSecond),
                    maximum: maximumMBps,
                    size: size,
                    color: downloadColor,
                    context: &context
                )
                drawLine(
                    values: points.map(\.decryptBytesPerSecond),
                    maximum: maximumMBps,
                    size: size,
                    color: decryptColor,
                    context: &context
                )
            }
        }
        .animation(.easeOut(duration: 0.2), value: points)
    }

    private func axisLabel(_ value: Double) -> String {
        String(
            format: "%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    private func drawLine(
        values: [Double],
        maximum: Double,
        size: CGSize,
        color: Color,
        context: inout GraphicsContext
    ) {
        guard !values.isEmpty, maximum > 0 else { return }
        let step = values.count > 1
            ? (size.width - 8) / CGFloat(values.count - 1)
            : 0
        let chartPoint: (Int, Double) -> CGPoint = { index, bytesPerSecond in
            let megabytesPerSecond = bytesPerSecond / 1_000_000
            return CGPoint(
                x: values.count > 1 ? 4 + CGFloat(index) * step : size.width / 2,
                y: 4 + (size.height - 8)
                    * (1 - CGFloat(min(megabytesPerSecond / maximum, 1)))
            )
        }

        var path = Path()
        for (index, value) in values.enumerated() {
            let point = chartPoint(index, value)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )

        guard let lastValue = values.last else { return }
        let lastPoint = chartPoint(values.count - 1, lastValue)
        context.fill(
            Path(ellipseIn: CGRect(
                x: lastPoint.x - 2,
                y: lastPoint.y - 2,
                width: 4,
                height: 4
            )),
            with: .color(color)
        )
    }
}

/// 曲目总时长的展示格式，仿 Apple Music 专辑/歌单底注：单位随长短自动切换，
/// 不足 1 小时用「X 分钟」，否则用「X 小时 Y 分钟」并在整点省略分钟。时长是目录
/// 元数据，下载中也可用；没有任何时长（合计为 0，如旧后端）时返回 nil。
enum TrackDurationSummary {
    static func totalDurationText(for items: [JobItem]) -> String? {
        let totalMs = items.reduce(0) { $0 + ($1.durationMs ?? 0) }
        return totalDurationText(totalMilliseconds: totalMs)
    }

    static func totalDurationText(totalMilliseconds: Int) -> String? {
        guard totalMilliseconds > 0 else { return nil }
        let totalMinutes = Int((Double(totalMilliseconds) / 60_000).rounded())
        guard totalMinutes > 0 else { return nil }
        if totalMinutes < 60 {
            return "\(totalMinutes) 分钟"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分钟"
    }
}

/// 曲目总大小的展示格式。`file_size` 要等文件落盘（或发现已存在）才有值，所以在此
/// 之前用「码率 × 时长」估算，并给每首补一份元数据开销——封面图和标签在成品文件里
/// 真实占位，却算不进音频码率。只要还有一首是估出来的，整行就说「约」；每首都拿到
/// 真实大小才说「共」。一首都算不出（如 aac-lc 没有逐曲清单可读码率，且尚未下载）
/// 时返回 nil，宁可不显示也不瞎猜。
enum TrackSizeEstimator {
    /// 每首歌的元数据补偿字节数。按十进制 MB 记，与展示用的 `.file` 口径一致。
    static let metadataOverheadBytes = 1_200_000.0

    static func estimatedBytes(for item: JobItem, fallbackBitrate: Int?) -> Double? {
        guard let durationMs = item.durationMs, durationMs > 0 else { return nil }
        guard let bitrate = positive(item.bitrate) ?? fallbackBitrate else { return nil }
        return Double(bitrate) * (Double(durationMs) / 1000) / 8 + metadataOverheadBytes
    }

    static func representativeBitrate(for items: [JobItem]) -> Int? {
        let known = items.compactMap { positive($0.bitrate) }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / known.count
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

enum TrackSizeSummary {

    static func totalSizeText(for items: [JobItem]) -> String? {
        // 同一张专辑各曲码率一致，所以某首还没解析出码率时，用已知曲目的均值顶上——
        // 只要有一首进了下载阶段，整张专辑就能给出估算。
        let fallbackBitrate = TrackSizeEstimator.representativeBitrate(for: items)
        var exactBytes: Int64 = 0
        var estimatedBytes = 0.0
        var hasEstimate = false

        for item in items {
            if let fileSize = item.fileSize, fileSize > 0 {
                exactBytes += fileSize
                continue
            }
            guard let itemEstimate = TrackSizeEstimator.estimatedBytes(
                for: item,
                fallbackBitrate: fallbackBitrate
            ) else {
                continue
            }
            estimatedBytes += itemEstimate
            hasEstimate = true
        }

        let total = exactBytes + Int64(estimatedBytes.rounded())
        guard total > 0 else { return nil }
        let formatted = total.formatted(.byteCount(style: .file))
        return hasEstimate ? "约 \(formatted)" : "共 \(formatted)"
    }

}

/// 「流派 · 年份 · 音质 · 区域」那一行。方形概览和竖版出血头图共用，保证两种
/// 版式下这一行的排版完全一致。
struct JobCaptionRow: View {
    let job: Job
    let items: [JobItem]
    let color: Color
    @Binding var presentedQualityDetails: AudioQualityPresentation.Details?

    var segments: [CaptionSegment] {
        var out: [CaptionSegment] = []
        if let genre = nonempty(job.genre) {
            out.append(.text(id: "genre", value: genre))
        }
        if let releaseDate = job.releaseDate, releaseDate.count >= 4 {
            let year = String(releaseDate.prefix(4))
            if year.allSatisfy(\.isNumber) {
                out.append(.text(id: "year", value: "\(year)年"))
            }
        }
        if job.type == .song || job.type == .album {
            out.append(contentsOf: AudioQualityPresentation.badges(for: items).map { .badge($0) })
        }
        if let storefront = nonempty(job.storefront) {
            out.append(.text(id: "storefront", value: storefront.uppercased()))
        }
        return out
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments) { segment in
                if segment.id != segments.first?.id {
                    Text("·")
                }
                switch segment {
                case .text(_, let text):
                    Text(text)
                case .badge(let badge):
                    Button {
                        presentedQualityDetails = AudioQualityPresentation.details(for: items)
                    } label: {
                        QualityBadgeView(badge: badge)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(badge.accessibilityLabel)，查看音质详情")
                    .accessibilityHint("轻点查看位深度、采样率和码率")
                }
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CaptionSegment: Identifiable {
    case text(id: String, value: String)
    case badge(AudioQualityPresentation.Badge)

    var id: String {
        switch self {
        case .text(let id, _):
            "text:\(id)"
        case .badge(let badge):
            "badge:\(badge.id)"
        }
    }
}

/// 发行日期（后端给的是 `YYYY-MM-DD`）的长格式展示。集合页底注和「详细信息」表
/// 共用；解析不出来时原样返回，宁可显示原始字符串也不吞掉。
enum ReleaseDatePresentation {
    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func longText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(date: .long, time: .omitted)
    }
}

struct DownloadDetailFooterView: View {
    let job: Job
    let items: [JobItem]
    let palette: DownloadDetailPalette?

    private var formattedReleaseDate: String? {
        ReleaseDatePresentation.longText(job.releaseDate)
    }

    private var songCountText: String? {
        guard job.totalItems > 0 else { return nil }
        var parts = ["\(job.totalItems) 首歌"]
        if let totalDurationText = TrackDurationSummary.totalDurationText(for: items) {
            parts.append(totalDurationText)
        }
        if let totalSizeText = TrackSizeSummary.totalSizeText(for: items) {
            parts.append(totalSizeText)
        }
        return parts.joined(separator: "，")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4.333) {
            if let songCountText {
                Text(songCountText)
            }
            if let formattedReleaseDate {
                Text("专辑发行于 \(formattedReleaseDate)")
            }
            Text("任务创建于 \(job.createdAt.formatted(date: .abbreviated, time: .shortened))")
        }
        .font(.footnote)
        .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 7)
        .padding(.bottom, 8)
    }
}
