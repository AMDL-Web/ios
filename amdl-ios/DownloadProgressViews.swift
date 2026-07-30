//
//  DownloadProgressViews.swift
//  amdl-ios
//

import SwiftUI

struct ThinProgressBar: View {
    let progress: Double
    let tint: Color
    var height: CGFloat = 4

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.15))

                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * clampedProgress)
            }
        }
        .frame(height: height)
        .animation(.smooth, value: clampedProgress)
    }
}

/// 分段进度条：一根条同时说两件事 —— 下完了几首，和整体走到哪了。
///
/// 和 Web 端详情页的 `.jd-bar` 是同一套画法：实心段 + 半透明段 + 每首一格的刻度。
/// 但两段各自代表什么是这边自己定的，因为两端的「进度」本来就不是一个数：
///
/// - **实心段** = 已结束的曲目 ÷ 总数。它只会整格整格地跳，所以永远落在刻度上，
///   一眼数得出「14 首下完了 7 首」。
/// - **半透明段** = 详情页那个百分比本身（`DownloadDetail.progress`，所有曲目
///   进度的平均）。于是旁边那个大数字就是这一段的尖端，条和数字不可能各说各的 ——
///   而它超出实心段的那一截，正好就是同时在下的那几首各自的零头。
/// - **刻度** = 曲目分隔线。多到画出来只剩一片糊的时候就不画。
///
/// 单曲进度怎么折算成 0..1 不归这里管，那是 `ItemProgress.fraction` 的事。
/// 这个视图只管怎么画，两个比例都由调用方算好传进来。
struct SegmentedProgressBar: View {
    /// 实心段的位置，0...1。
    let done: Double
    /// 半透明段的位置，0...1。小于等于 `done` 时不画。
    let live: Double
    /// 刻度格数（曲目数）。0 表示不画刻度。
    var ticks: Int = 0
    let tint: Color
    /// 刻度线的颜色。刻度是把条**切开**，所以给页面底色，不是在条上描一道线。
    var tickColor: Color = .clear
    var height: CGFloat = 4

    private var clampedDone: Double {
        min(max(done, 0), 1)
    }

    private var clampedLive: Double {
        min(max(live, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.15))

                // 先画淡的再画实的：两段都从最左边起算，实心段直接盖在半透明段上，
                // 露出来的那一截就是「正在下、还没下完」的部分。
                if clampedLive > clampedDone {
                    Capsule()
                        .fill(tint.opacity(0.38))
                        .frame(width: geometry.size.width * clampedLive)
                }

                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * clampedDone)
            }
            // 刻度压在最上面，实心段和半透明段一起被切开。
            .overlay {
                if ticks >= 2 {
                    SegmentTicks(count: ticks, lineWidth: 1.5)
                        .fill(tickColor)
                }
            }
        }
        .frame(height: height)
        .animation(.smooth, value: clampedDone)
        .animation(.smooth, value: clampedLive)
    }
}

/// 把一根条等分成 `count` 格的分隔线。线画在每一格的右边缘，最后一格那条正好
/// 落在条的外沿上、被裁掉，所以看得见的是 `count - 1` 条。
private struct SegmentTicks: Shape {
    let count: Int
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count >= 2 else { return path }
        for index in 1..<count {
            let x = rect.width * CGFloat(index) / CGFloat(count)
            path.addRect(
                CGRect(x: x - lineWidth, y: rect.minY, width: lineWidth, height: rect.height)
            )
        }
        return path
    }
}

struct ProgressRing: View {
    let progress: Double
    let tint: Color

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.2), lineWidth: 2.5)

            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 22, height: 22)
        .animation(.smooth, value: clampedProgress)
    }
}

#Preview("分段进度条") {
    // 底色要和详情页一致：刻度就是拿它把条切开的，配错了刻度会变成描在条上的线。
    let background = Color(.systemGroupedBackground)

    func row(_ caption: String, @ViewBuilder bar: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            bar()
        }
    }

    return VStack(alignment: .leading, spacing: 22) {
        row("11 首 · 下完 3 首，第 4 首下到一半") {
            SegmentedProgressBar(
                done: 3.0 / 11,
                live: 3.5 / 11,
                ticks: 11,
                tint: .orange,
                tickColor: background,
                height: 5
            )
        }
        row("11 首 · 同时在下好几首") {
            SegmentedProgressBar(
                done: 3.0 / 11,
                live: 6.2 / 11,
                ticks: 11,
                tint: .orange,
                tickColor: background,
                height: 5
            )
        }
        row("11 首 · 全部完成") {
            SegmentedProgressBar(
                done: 1, live: 1, ticks: 11,
                tint: .green, tickColor: background, height: 5
            )
        }
        row("40 首 · 超过刻度上限，不画分隔线") {
            SegmentedProgressBar(
                done: 12.0 / 40,
                live: 15.4 / 40,
                ticks: 0,
                tint: .orange,
                tickColor: background,
                height: 5
            )
        }
        row("单曲 · 不分段，和以前一样") {
            SegmentedProgressBar(
                done: 0.62, live: 0, ticks: 0,
                tint: .orange, tickColor: background, height: 5
            )
        }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(background)
}
