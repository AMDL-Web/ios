//
//  Job+MotionArtwork.swift
//  amdl-ios
//

import SwiftUI

extension Job {
    /// 方形动态封面的 HLS。后端解析后异步回填，所以同一个任务可能先是 nil。
    var motionArtworkVideoURL: URL? {
        guard let raw = motionArtworkURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// 动态封面自带的调色板，取自它自己的 previewFrame，和静态封面那套差别很大：
    /// 同一张专辑静态封面是 `598090` 配近黑文字，方形动态是 `5c6786` 配近白。
    /// Apple Music 用的就是当前展示资产的那套，混用会得到深底深字。
    var motionArtworkPalette: DownloadDetailPalette? {
        guard let background = Color(hexRGB: motionArtworkBgColor) else { return nil }
        let primary = Color(hexRGB: motionArtworkTextColor1) ?? .primary
        let secondary = Color(hexRGB: motionArtworkTextColor2) ?? primary.opacity(0.8)
        return DownloadDetailPalette(
            background: background,
            primaryText: primary,
            secondaryText: secondary,
            tertiaryText: Color(hexRGB: motionArtworkTextColor3) ?? secondary
        )
    }
}
