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
