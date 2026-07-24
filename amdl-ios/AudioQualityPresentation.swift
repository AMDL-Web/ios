//
//  AudioQualityPresentation.swift
//  amdl-ios
//

import SwiftUI

/// 音质徽标与精确参数展示。无损和沉浸式编码沿用 Apple Music 风格品牌
/// 标识；其他编码使用中性文字入口，确保位深度、采样率和码率始终可查看。
enum AudioQualityPresentation {
    enum Glyph: Hashable {
        case dolbyAtmos
        case hiRes
    }

    struct Badge: Hashable, Identifiable {
        let glyph: Glyph?
        let label: String

        var id: String {
            "\(String(describing: glyph))|\(label)"
        }

        var accessibilityLabel: String {
            switch glyph {
            case .dolbyAtmos:
                "Dolby Atmos"
            case .hiRes:
                label.isEmpty ? "高解析度无损" : label
            case nil:
                label
            }
        }
    }

    struct Details: Identifiable, Equatable {
        let title: String
        let message: String

        var id: String {
            "\(title)|\(message)"
        }
    }

    static func badges(for items: [JobItem]) -> [Badge] {
        var hasAtmos = false
        var hasLossless = false
        var hasHiRes = false

        for item in items {
            guard let codec = item.codec?.lowercased(), !codec.isEmpty else { continue }
            if codec.contains("ec3") || codec.contains("ec-3")
                || codec.contains("ac3") || codec.contains("ac-3")
                || codec.contains("atmos") {
                hasAtmos = true
            }
            if codec.contains("alac") || codec.contains("flac") {
                hasLossless = true
                if let sampleRate = item.sampleRate, sampleRate > 48000 {
                    hasHiRes = true
                }
            }
        }

        var badges: [Badge] = []
        if hasAtmos {
            // 官方 lockup 自带 DOLBY ATMOS 字标，不另加文字。
            badges.append(Badge(glyph: .dolbyAtmos, label: ""))
        }
        if hasHiRes {
            badges.append(Badge(glyph: .hiRes, label: "高解析度无损"))
        } else if hasLossless {
            // 普通无损没有官方图标可用，纯文字。
            badges.append(Badge(glyph: nil, label: "无损"))
        }
        return badges
    }

    static func badges(for item: JobItem) -> [Badge] {
        let branded = badges(for: [item])
        if !branded.isEmpty {
            return branded
        }

        var labels: [String] = []
        if let codec = normalizedCodec(item.codec) {
            labels.append(codec)
        }
        if let qualityText = item.qualityText {
            labels.append(qualityText)
        }
        if labels.isEmpty, hasTechnicalValues(item) {
            labels.append("音质")
        }
        return labels.isEmpty ? [] : [Badge(glyph: nil, label: labels.joined(separator: " · "))]
    }

    static func hasDetails(for item: JobItem) -> Bool {
        normalizedCodec(item.codec) != nil || hasTechnicalValues(item)
    }

    static func details(for items: [JobItem], title: String = "音质详情") -> Details {
        let codecs = distinct(items.compactMap { normalizedCodec($0.codec) })
        let bitDepths = distinct(items.compactMap { positive($0.bitDepth) }).map { "\($0) 位" }
        let sampleRates = distinct(items.compactMap { positive($0.sampleRate) }).map(sampleRateText)
        let bitrates = distinct(items.compactMap { positive($0.bitrate) }).map(bitrateText)

        let message = [
            "编码：\(joinedOrUnavailable(codecs))",
            "位深度：\(joinedOrUnavailable(bitDepths))",
            "采样率：\(joinedOrUnavailable(sampleRates))",
            "码率：\(joinedOrUnavailable(bitrates))"
        ].joined(separator: "\n")

        return Details(title: title, message: message)
    }

    static func accessibilitySummary(for item: JobItem) -> String {
        let codec = normalizedCodec(item.codec) ?? "音质"
        let values = [
            positive(item.bitDepth).map { "\($0) 位" },
            positive(item.sampleRate).map(kilohertzText),
            positive(item.bitrate).map(bitrateText)
        ].compactMap { $0 }
        return ([codec] + values).joined(separator: "，")
    }

    private static func normalizedCodec(_ codec: String?) -> String? {
        guard let codec = codec?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codec.isEmpty else {
            return nil
        }
        return codec.uppercased()
    }

    private static func hasTechnicalValues(_ item: JobItem) -> Bool {
        positive(item.bitDepth) != nil
            || positive(item.sampleRate) != nil
            || positive(item.bitrate) != nil
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func distinct<T: Hashable & Comparable>(_ values: [T]) -> [T] {
        Array(Set(values)).sorted()
    }

    private static func joinedOrUnavailable(_ values: [String]) -> String {
        values.isEmpty ? "暂无数据" : values.joined(separator: "、")
    }

    private static func sampleRateText(_ value: Int) -> String {
        kilohertzText(value)
    }

    private static func kilohertzText(_ value: Int) -> String {
        let kilohertz = Double(value) / 1000
        let number = kilohertz.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", kilohertz)
            : String(format: "%.1f", kilohertz)
        return "\(number) kHz"
    }

    private static func bitrateText(_ value: Int) -> String {
        let kilobits = Double(value) / 1000
        let number = kilobits.truncatingRemainder(dividingBy: 1) == 0
            ? (value / 1000).formatted()
            : String(format: "%.1f", kilobits)
        return "\(number) kbps"
    }
}

/// 音质徽标。Dolby 用官方完整 lockup（双 D + 字标一体的 SVG，模板渲染跟随
/// 前景色，不再自行拼文字）；高解析度无损用 Hi-Res AUDIO 小金标（保留原色）
/// 加文案；普通无损无官方图标、只显示文字。
struct QualityBadgeView: View {
    let badge: AudioQualityPresentation.Badge

    var body: some View {
        HStack(spacing: 3) {
            switch badge.glyph {
            case .dolbyAtmos:
                Image("DolbyAtmosGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 10)
                    .accessibilityHidden(true)
            case .hiRes:
                Image("HiResAudioBadge")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 14)
                    .accessibilityHidden(true)
            case nil:
                EmptyView()
            }

            if !badge.label.isEmpty {
                Text(badge.label)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.accessibilityLabel)
    }
}

enum SongDetailPresentation {
    static func subtitle(item: JobItem?) -> String? {
        guard let item else { return nil }
        let metadata = [item.artist, item.album].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !metadata.isEmpty else { return nil }
        return metadata.joined(separator: " — ")
    }

    static func statusText(job: Job, item: JobItem?) -> String {
        if job.status == .failed || item?.status == .failed {
            return "失败"
        }
        if job.status == .completed || item?.status == .completed
            || item?.status == .skippedExisting {
            return "完成"
        }
        if job.status == .cancelled || item?.status == .cancelled {
            return "已取消"
        }
        return "下载中"
    }
}
