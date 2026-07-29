import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

struct DownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(activityURL(for: context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityArtwork(state: context.state, size: 64)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    expandedTitle(context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(context.state)
                        .padding(.trailing, 6)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(context.state)
                }
            } compactLeading: {
                if context.state.mode == "multiple" {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 22, height: 22)
                        .padding(.leading, 1)
                } else {
                    ActivityArtwork(state: context.state, size: 22)
                        .padding(.leading, 1)
                }
            } compactTrailing: {
                trailingValue(context.state)
            } minimal: {
                if context.state.mode == "multiple" {
                    Text("\(context.state.activeCount)")
                        .font(.caption2.bold().monospacedDigit())
                } else if context.state.status == "completed" {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                } else {
                    Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(statusTint(context.state.status))
                }
            }
            .widgetURL(activityURL(for: context.state))
            .keylineTint(.blue)
        }
    }

    @ViewBuilder
    private func expandedTitle(_ state: DownloadActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if state.mode == "multiple" {
                Text("下载任务")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
            } else {
                FadingText(state.title, font: .headline.weight(.semibold))
            }

            Text(state.mode == "multiple" ? "\(state.activeCount) 个任务正在运行" : statusText(state.status))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func expandedTrailing(_ state: DownloadActivityAttributes.ContentState) -> some View {
        if state.mode == "multiple" {
            Text("\(state.activeCount)")
                .font(.title2.bold().monospacedDigit())
        } else if state.status == "completed" {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.green)
        } else if state.status == "failed" {
            Image(systemName: "xmark.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.red)
        } else if state.status == "cancelled" {
            Image(systemName: "minus.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
        } else {
            Text(state.progress, format: .percent.precision(.fractionLength(0)))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(statusTint(state.status))
        }
    }

    @ViewBuilder
    private func trailingValue(_ state: DownloadActivityAttributes.ContentState) -> some View {
        if state.mode == "multiple" {
            ZStack {
                Circle()
                    .stroke(Color.blue, lineWidth: 1.25)
                Text("\(state.activeCount)")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
            .padding(.trailing, 3)
        } else if state.status == "completed" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if state.status == "failed" {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else if state.status == "cancelled" {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        } else {
            Text(state.progress, format: .percent.precision(.fractionLength(0)))
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(statusTint(state.status))
        }
    }

    private func activityURL(for state: DownloadActivityAttributes.ContentState) -> URL? {
        var components = URLComponents()
        components.scheme = "amdl"
        if state.mode == "single", let jobID = state.jobID, !jobID.isEmpty {
            components.host = "download"
            components.path = "/\(jobID)"
        } else {
            components.host = "downloads"
        }
        return components.url
    }

    @ViewBuilder
    private func expandedBottom(_ state: DownloadActivityAttributes.ContentState) -> some View {
        if state.mode == "multiple" {
            Text("\(state.activeCount) 个任务正在运行")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
                .padding(.bottom, 6)
        } else {
            expandedProgressBar(state)
                .padding(.top, 8)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
    }

    private func expandedProgressBar(_ state: DownloadActivityAttributes.ContentState) -> some View {
        ActivityProgressTrack(
            progress: state.progress,
            tint: statusTint(state.status)
        )
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "queued": "排队中"
        case "running": "正在下载"
        case "completed": "下载完成"
        case "failed": "下载失败"
        case "cancelled": "已取消"
        default: status
        }
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "completed": .green
        case "failed": .red
        case "cancelled": .secondary
        default: .blue
        }
    }

}

private struct FadingText: View {
    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    init(_ text: String, font: Font) {
        self.text = text
        self.font = font
    }

    private var isOverflowing: Bool {
        textWidth > containerWidth
    }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(0)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: FadingTextWidthKey.self, value: proxy.size.width)
                        }
                    }
                }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask {
                if isOverflowing {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.85),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Rectangle()
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: FadingTextContainerWidthKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(FadingTextWidthKey.self) { textWidth = $0 }
            .onPreferenceChange(FadingTextContainerWidthKey.self) { containerWidth = $0 }
    }
}

private struct FadingTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FadingTextContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DownloadLockScreenView: View {
    let state: DownloadActivityAttributes.ContentState

    @ViewBuilder
    var body: some View {
        if state.mode == "multiple" {
            HStack(spacing: 12) {
                ActivityArtwork(state: state, size: 56)

                VStack(alignment: .leading, spacing: 3) {
                    Text("下载任务")
                        .font(.headline)
                    Text("\(state.activeCount) 个任务正在运行")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ActivityArtwork(state: state, size: 56)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.title)
                            .font(.headline)
                            .lineLimit(1)

                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if state.status == "completed" {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3.bold())
                            .foregroundStyle(.green)
                    } else if state.status == "failed" {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3.bold())
                            .foregroundStyle(.red)
                    } else {
                        Text(state.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(statusTint)
                    }
                }

                ActivityProgressTrack(progress: state.progress, tint: statusTint)
            }
            .padding(16)
        }
    }

    private var statusText: String {
        switch state.status {
        case "queued": "排队中"
        case "running": "下载中"
        case "completed": "已完成"
        case "failed": "失败"
        case "cancelled": "已取消"
        default: state.status
        }
    }

    private var statusTint: Color {
        switch state.status {
        case "completed": .green
        case "failed": .red
        default: .blue
        }
    }
}

private struct ActivityProgressTrack: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let clampedProgress = min(max(progress, 0), 1)
            let trackHeight: CGFloat = 6
            let fillWidth = min(max(proxy.size.width * clampedProgress, trackHeight), proxy.size.width)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.2))
                    .frame(height: trackHeight)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.75), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth, height: trackHeight)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 6)
    }
}

private struct ActivityArtwork: View {
    let state: DownloadActivityAttributes.ContentState
    let size: CGFloat

    private struct PixelGrid {
        let dimension: Int
        let rgba: [UInt8]
    }

    private var artwork: PixelGrid? {
        guard state.mode != "multiple",
              let artworkURL = state.artworkURL,
              let fileURL = LiveActivityArtworkStore.fileURL(for: artworkURL),
              let source = UIImage(contentsOfFile: fileURL.path)?.cgImage
        else { return nil }

        let dimension = size <= 24 ? 96 : 192
        var rgba = [UInt8](repeating: 0, count: dimension * dimension * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: dimension * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            return true
        }
        return rendered ? PixelGrid(dimension: dimension, rgba: rgba) : nil
    }

    @ViewBuilder
    var body: some View {
        if let artwork {
            Canvas { context, canvasSize in
                let cellHeight = canvasSize.height / CGFloat(artwork.dimension)
                for row in 0..<artwork.dimension {
                    var stops: [Gradient.Stop] = []
                    stops.reserveCapacity(artwork.dimension)
                    for column in 0..<artwork.dimension {
                        let offset = (row * artwork.dimension + column) * 4
                        let color = Color(
                            .sRGB,
                            red: Double(artwork.rgba[offset]) / 255,
                            green: Double(artwork.rgba[offset + 1]) / 255,
                            blue: Double(artwork.rgba[offset + 2]) / 255,
                            opacity: Double(artwork.rgba[offset + 3]) / 255
                        )
                        stops.append(
                            Gradient.Stop(
                                color: color,
                                location: CGFloat(column) / CGFloat(artwork.dimension - 1)
                            )
                        )
                    }
                    let y = CGFloat(row) * cellHeight
                    let rect = CGRect(
                        x: 0,
                        y: y,
                        width: canvasSize.width,
                        height: cellHeight + 0.25
                    )
                    context.fill(
                        Path(rect),
                        with: .linearGradient(
                            Gradient(stops: stops),
                            startPoint: CGPoint(x: 0, y: y),
                            endPoint: CGPoint(x: canvasSize.width, y: y)
                        )
                    )
                }
            }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
                .id(state.artworkRevision ?? state.artworkURL ?? "artwork")
        } else {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Color.white.opacity(0.15))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: state.mode == "multiple" ? "square.stack.3d.up.fill" : "arrow.down")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.blue)
                }
        }
    }
}

#Preview("单任务", as: .content, using: DownloadActivityAttributes(gatewayID: "preview")) {
    DownloadLiveActivityWidget()
} contentStates: {
    DownloadActivityAttributes.ContentState(
        mode: "single",
        jobID: "job-1",
        title: "Example Album",
        status: "running",
        progress: 0.42,
        activeCount: 1
    )
}

#Preview("展开灵动岛", as: .dynamicIsland(.expanded), using: DownloadActivityAttributes(gatewayID: "preview")) {
    DownloadLiveActivityWidget()
} contentStates: {
    DownloadActivityAttributes.ContentState(
        mode: "single",
        jobID: "job-1",
        title: "夜に駆ける - Single",
        status: "running",
        progress: 0.42,
        activeCount: 1
    )
}
