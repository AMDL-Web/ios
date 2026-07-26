//
//  MotionArtworkStyle.swift
//  amdl-ios
//

import SwiftUI

/// 动态封面的展示形态。存本地偏好，不上传后端 —— 这是纯展示选择，两种形态用的
/// 是同一个任务下发的两条 HLS。
enum MotionArtworkStyle: String, CaseIterable, Identifiable {
    /// 1:1 方形，沿用原本的圆角卡片版式。
    case square
    /// 3:4 竖版，铺满顶部做出血背景，标题压在画面上——Apple Music 专辑页的做法。
    case tall

    static let storageKey = "motionArtworkStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: "方形封面"
        case .tall: "竖版全屏"
        }
    }

    var caption: String {
        switch self {
        case .square: "1:1，动态封面盖在原本的方形封面上"
        case .tall: "3:4，动态封面铺满顶部，标题压在画面上"
        }
    }
}

extension Job {
    /// 按展示形态取对应的视频。**两种形态用的是不同的资产**，别混。
    func motionArtworkVideoURL(style: MotionArtworkStyle) -> URL? {
        let raw = switch style {
        case .square: motionArtworkURL
        case .tall: motionArtworkTallURL
        }
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// 每个变体自带一套配色，取自它自己的 previewFrame，和静态封面那套差别很大：
    /// 同一张专辑静态封面是 `598090` 配近黑文字，方形动态是 `5c6786` 配近白，
    /// 竖版是 `05104b` 配浅色。Apple Music 用的就是当前展示资产的那套，所以它的
    /// 背景看起来和静态封面完全不同。拿静态配色去配动态资产会得到深底深字。
    func motionArtworkPalette(style: MotionArtworkStyle) -> DownloadDetailPalette? {
        let bg: String?
        let t1: String?
        let t2: String?
        let t3: String?
        switch style {
        case .square:
            bg = motionArtworkBgColor
            t1 = motionArtworkTextColor1
            t2 = motionArtworkTextColor2
            t3 = motionArtworkTextColor3
        case .tall:
            bg = motionArtworkTallBgColor
            t1 = motionArtworkTallTextColor1
            t2 = motionArtworkTallTextColor2
            t3 = motionArtworkTallTextColor3
        }
        guard let background = Color(hexRGB: bg) else { return nil }
        let primary = Color(hexRGB: t1) ?? .primary
        let secondary = Color(hexRGB: t2) ?? primary.opacity(0.8)
        return DownloadDetailPalette(
            background: background,
            primaryText: primary,
            secondaryText: secondary,
            tertiaryText: Color(hexRGB: t3) ?? secondary
        )
    }
}

/// 配置页里的形态选择。只影响有动态封面的专辑；没有的任务两种形态看起来一样。
struct MotionArtworkStylePicker: View {
    @AppStorage(MotionArtworkStyle.storageKey) private var rawValue = MotionArtworkStyle.square.rawValue

    private var selection: Binding<MotionArtworkStyle> {
        Binding(
            get: { MotionArtworkStyle(rawValue: rawValue) ?? .square },
            set: { rawValue = $0.rawValue }
        )
    }

    var body: some View {
        Picker(selection: selection) {
            ForEach(MotionArtworkStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        } label: {
            Label("动态封面", systemImage: "play.square.stack.fill")
        }
        .pickerStyle(.menu)

        Text(selection.wrappedValue.caption)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
