//
//  MotionArtworkTallHeader.swift
//  amdl-ios
//

import SwiftUI

/// 竖版动态封面的出血头图 —— Apple Music 专辑页的做法：3:4 视频铺满顶部并顶到
/// 状态栏后面，标题、艺人、元信息压在画面下缘，再渐变过渡到背景色接住下方的曲目
/// 列表。
///
/// 只在确实有 3:4 动态封面时使用；没有的话详情页仍走方形卡片版式。
struct MotionArtworkTallHeader: View {
    let job: Job
    let items: [JobItem]
    @Binding var presentedQualityDetails: AudioQualityPresentation.Details?
    let videoURL: URL
    let palette: DownloadDetailPalette

    /// 3:4。视频本身是 2048×2732，比例一致。
    private static let aspectRatio: CGFloat = 3.0 / 4.0

    var body: some View {
        // 下拉时上边缘钉住、画面顺势放大，而不是整块跟着往下滑——列表头图的常规
        // 做法：量出自身在全局坐标里的 minY，正值就是被下拉的距离。
        GeometryReader { proxy in
            let pulled = max(0, proxy.frame(in: .global).minY)
            content(extraHeight: pulled)
                .frame(width: proxy.size.width, height: proxy.size.height + pulled)
                .offset(y: -pulled)
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
    }

    private func content(extraHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            MotionArtworkPlayer(url: videoURL)
                .scaledToFill()

            // 画面下缘压着文字，需要一层由背景色渐变上来的遮罩才读得清；同时它也
            // 负责把视频底边接进下方列表的背景，避免一条硬边。
            // 对着 Apple Music 的截图量过明度曲线：它的封面到屏高 55% 仍有 ~120
            // 亮度，而早先这里压到 32。所以遮罩要晚开始、也不要那么快压满，只在
            // 文字带附近给足对比即可。
            LinearGradient(
                stops: [
                    .init(color: palette.background.opacity(0), location: 0),
                    .init(color: palette.background.opacity(0), location: 0.58),
                    .init(color: palette.background.opacity(0.30), location: 0.80),
                    .init(color: palette.background.opacity(0.62), location: 0.94),
                    .init(color: palette.background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 2) {
                Text(job.displayName)
                    .font(.title2.bold())
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 1)

                if let subtitle = job.artistName, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
                        .padding(.top, 1.5)
                }

                // 元信息行跟着艺人名走，而不是留给下面的概览——放在概览里会额外吃
                // 掉 section 间距，实测拉出 44.7pt 的空档，Apple 那边只有 12.7pt。
                JobCaptionRow(
                    job: job,
                    items: items,
                    color: palette.tertiaryText,
                    presentedQualityDetails: $presentedQualityDetails
                )
                // 对着参考图量：Apple 的艺人→元信息是 12.7pt。VStack 自带 2pt，
                // 文字行盒本身还占掉约 7.3pt，所以这里只补剩下的。
                .padding(.top, 3.4)
            }
            .padding(.horizontal, 24)
            // 量参考图得到：Apple 的元信息行底部距画面底 48.3pt。
            .padding(.bottom, 45.7)
        }

    }
}
