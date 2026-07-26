//
//  DownloadDetailSummaryView.swift
//  amdl-ios
//

import SwiftUI

struct DownloadSongDetailContent: View {
    let job: Job?
    let items: [JobItem]
    let progress: Double
    var downloadSpeed: Double = 0
    var decryptSpeed: Double = 0
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
                            downloadSpeed: downloadSpeed,
                            decryptSpeed: decryptSpeed,
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
    var downloadSpeed: Double = 0
    var decryptSpeed: Double = 0
    let albumTracksOmitSubtitles: Bool
    let palette: DownloadDetailPalette?
    @Binding var presentedQualityDetails: AudioQualityPresentation.Details?

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

    /// 仅在任务活跃且确实有速度可估时展示速度行，避免终态或 AAC-LC（无码率
    /// 可估）时留一行空占位。
    private var showsSpeedReadout: Bool {
        job.status.isActive && (downloadSpeed > 0 || decryptSpeed > 0)
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
                .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
                .padding(.horizontal, 32.5)
                .padding(.bottom, 11.5)

            VStack(spacing: 2) {
                Text(job.displayName)
                    .font(.title2.bold())
                    .foregroundStyle(palette?.primaryText ?? Color.primary)
                    .multilineTextAlignment(.center)

                if let headlineSubtitle {
                    Text(headlineSubtitle)
                        .font(.title3)
                        .foregroundStyle(palette?.secondaryText ?? Self.artistLineColor)
                        .multilineTextAlignment(.center)
                        .padding(.top, 1.5)
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

                if showsSpeedReadout {
                    HStack(spacing: 12) {
                        if downloadSpeed > 0 {
                            Label(
                                TransferSpeedFormat.string(bytesPerSecond: downloadSpeed),
                                systemImage: "arrow.down"
                            )
                        }
                        if decryptSpeed > 0 {
                            Label(
                                TransferSpeedFormat.string(bytesPerSecond: decryptSpeed),
                                systemImage: "lock.open"
                            )
                        }
                        Spacer()
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
                }
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

struct DownloadDetailFooterView: View {
    let job: Job
    let items: [JobItem]
    let palette: DownloadDetailPalette?

    private static let releaseDateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var formattedReleaseDate: String? {
        guard let raw = job.releaseDate, !raw.isEmpty else { return nil }
        guard let date = Self.releaseDateParser.date(from: raw) else { return raw }
        return date.formatted(date: .long, time: .omitted)
    }

    private var songCountText: String? {
        guard job.totalItems > 0 else { return nil }
        let base = "\(job.totalItems) 首歌"
        guard let totalDurationText = TrackDurationSummary.totalDurationText(for: items) else {
            return base
        }
        return "\(base)，\(totalDurationText)"
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
