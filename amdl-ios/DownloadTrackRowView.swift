//
//  DownloadTrackRowView.swift
//  amdl-ios
//

import SwiftUI

struct DownloadTrackRowView: View {
    let item: JobItem
    let jobType: JobType
    let isFirst: Bool
    let isLast: Bool
    let albumArtistsAreUniform: Bool
    let separatorColor: Color
    let palette: DownloadDetailPalette?
    @Binding var presentedQualityDetails: AudioQualityPresentation.Details?

    private var usesAppleMusicLayout: Bool {
        jobType == .album || jobType.usesCollectionTrackPresentation
    }

    private var albumTracksOmitSubtitles: Bool {
        jobType == .album && albumArtistsAreUniform
    }

    private var showsItemQualityBadges: Bool {
        jobType != .album && jobType != .song
    }

    private var retryText: String? {
        guard let attempt = item.attempt, let maxAttempts = item.maxAttempts,
              maxAttempts > 0, attempt > 1 else {
            return nil
        }
        if let retryKind = item.retryKind, !retryKind.isEmpty {
            return "\(retryKind) 尝试 \(attempt)/\(maxAttempts)"
        }
        return "尝试 \(attempt)/\(maxAttempts)"
    }

    var body: some View {
        Group {
            if usesAppleMusicLayout {
                appleMusicRow
            } else {
                standardContent
                    .padding(.vertical, 2)
            }
        }
    }

    private var appleMusicRow: some View {
        VStack(spacing: 0) {
            if isFirst {
                Color.clear.frame(height: 1)
            }

            if jobType.usesCollectionTrackPresentation {
                collectionContent
                    .padding(.top, isFirst ? 10.333 : 9.333)
                    .padding(.bottom, 8.667)
                    .padding(.trailing, 5.333)
            } else if albumTracksOmitSubtitles {
                standardContent
                    .frame(minHeight: 51.333)
                    .padding(.trailing, 5.333)
            } else {
                standardContent
                    .padding(.top, isFirst ? 13.333 : 12.333)
                    .padding(.bottom, 6.667)
                    .padding(.trailing, 5.333)
            }

            if isLast {
                Color.clear.frame(height: 1)
            } else {
                Rectangle()
                    .fill(separatorColor)
                    .frame(height: 1)
                    .padding(.leading, 31)
            }
        }
        .frame(maxWidth: .infinity)
        .anchorPreference(key: DownloadTrackBoundsPreferenceKey.self, value: .bounds) { anchor in
            var result: [DownloadTrackEdge: Anchor<CGRect>] = [:]
            if isFirst {
                result[.first] = anchor
            }
            if isLast {
                result[.last] = anchor
            }
            return result
        }
    }

    private var standardContent: some View {
        HStack(alignment: .top, spacing: jobType == .album ? 9 : 10) {
            trackIndex(width: jobType == .album ? 22 : 28)

            VStack(alignment: .leading, spacing: jobType == .album ? 1.5 : 4) {
                Text(item.displayTitle)
                    .font(jobType == .album ? .callout : .body)
                    .foregroundStyle(palette?.primaryText ?? Color.primary)

                if let subtitle = itemSubtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
                        .lineLimit(1)
                }

                if showsItemQualityBadges && AudioQualityPresentation.hasDetails(for: item)
                    || retryText != nil {
                    metadataLine
                }

                if item.status == .failed || retryText != nil {
                    Text(item.statusText)
                        .font(.caption)
                        .foregroundStyle(
                            item.status == .failed
                                ? Color.red
                                : palette?.tertiaryText ?? Color.secondary
                        )
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
            statusAccessory.padding(.top, 1)
        }
    }

    private var collectionContent: some View {
        HStack(alignment: .top, spacing: 9) {
            trackIndex(width: 22)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(item.displayTitle)
                    .font(.callout)
                    .foregroundStyle(palette?.primaryText ?? Color.primary)

                Text(nonempty(item.album) ?? "未知专辑")
                    .font(.footnote)
                    .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
                    .lineLimit(1)

                Text(nonempty(item.artist) ?? "未知作者")
                    .font(.footnote)
                    .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
                    .lineLimit(1)

                if AudioQualityPresentation.hasDetails(for: item) {
                    qualityButton
                } else {
                    Text("音质信息待获取")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
                }

                if let retryText {
                    Text(retryText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }

                if item.status == .failed {
                    Text(item.statusText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
            statusAccessory.padding(.top, 1)
        }
        .padding(.vertical, 2)
    }

    private func trackIndex(width: CGFloat) -> some View {
        Text(item.index > 0 ? "\(item.index)" : "–")
            .font(
                usesAppleMusicLayout
                    ? Font.callout.monospacedDigit()
                    : Font.subheadline.monospacedDigit()
            )
            .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
            .frame(width: width, alignment: .center)
    }

    private var metadataLine: some View {
        HStack(spacing: 6) {
            if showsItemQualityBadges && AudioQualityPresentation.hasDetails(for: item) {
                Button(action: presentQualityDetails) {
                    HStack(spacing: 6) {
                        if let codec = nonempty(item.codec) {
                            MetadataBadgeView(text: codec.uppercased())
                        }
                        if let qualityText = item.qualityText {
                            MetadataBadgeView(text: qualityText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(AudioQualityPresentation.accessibilitySummary(for: item))，查看音质详情"
                )
                .accessibilityHint("轻点查看位深度、采样率和码率")
            }

            if let retryText {
                Text(retryText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
            }
        }
    }

    private var qualityButton: some View {
        Button(action: presentQualityDetails) {
            HStack(spacing: 5) {
                ForEach(AudioQualityPresentation.badges(for: item)) { badge in
                    QualityBadgeView(badge: badge)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(AudioQualityPresentation.accessibilitySummary(for: item))，查看音质详情"
        )
        .accessibilityHint("轻点查看位深度、采样率和码率")
    }

    @ViewBuilder
    private var statusAccessory: some View {
        let hasPartialProgress = item.clampedProgress > 0 && item.clampedProgress < 1
        Group {
            if (item.status.isActive && item.status != .queued) || hasPartialProgress {
                ProgressRing(
                    progress: item.clampedProgress,
                    tint: palette?.primaryText ?? item.status.tint
                )
            } else {
                switch item.status {
                case .completed, .skippedExisting:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                case .queued:
                    Image(systemName: "circle.dotted")
                        .font(.title3)
                        .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
                default:
                    Image(systemName: item.status.symbolName)
                        .font(.title3)
                        .foregroundStyle(palette?.secondaryText ?? item.status.tint)
                }
            }
        }
        .frame(width: 22, height: 22)
    }

    private var itemSubtitle: String? {
        guard jobType == .album else { return nonempty(item.subtitle) }
        guard !albumArtistsAreUniform else { return nil }
        return nonempty(item.artist)
    }

    private func presentQualityDetails() {
        presentedQualityDetails = AudioQualityPresentation.details(
            for: [item],
            title: "\(item.displayTitle) · 音质详情"
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct MetadataBadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
    }
}
