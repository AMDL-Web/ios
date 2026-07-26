//
//  MotionArtworkView.swift
//  amdl-ios
//

import AVFoundation
import CoreImage
import Combine
import SwiftUI
import UIKit

/// 盖在静态封面之上的动态封面图层。
///
/// URL 由后端下发（`motion_artwork_url`）。**不要试图在 App 里直接查 Apple Music**：
/// `editorialVideo` 不对第三方开放，MusicKit 走的 api.music.apple.com 永远返回空，
/// 只有后端用 web player token 打 amp-api 才拿得到。真机验证过。
///
/// 没有动态封面、开了「减弱动态效果」或低电量模式时整个视图不渲染任何东西，
/// 下面的 [JobArtworkView] 原样露出。
struct MotionArtworkView: View {
    let job: Job

    var body: some View {
        if let url = job.motionArtworkVideoURL {
            MotionArtworkPlayer(url: url)
        }
    }
}

/// 循环播放一段动态封面 HLS。方形覆盖层和竖版出血头图共用这一个 —— 静音、
/// 从不激活 AVAudioSession、遵守减弱动态效果 / 低电量 / 后台暂停。
struct MotionArtworkPlayer: View {
    let url: URL
    /// 首帧上屏前保持透明，避免黑底闪一下。方形模式下由调用方决定要不要淡入。
    var fadesIn: Bool = true

    @State private var isRendering = false
    @State private var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var shouldPlay: Bool {
        !reduceMotion && !isLowPowerMode && scenePhase == .active
    }

    var body: some View {
        MotionArtworkPlayerLayer(
            url: url,
            isPlaying: shouldPlay,
            onRenderingChange: { isRendering = $0 }
        )
        .opacity(fadesIn && !isRendering ? 0 : 1)
        .animation(.easeInOut(duration: 0.45), value: isRendering)
        .allowsHitTesting(false)
        .onChange(of: url) { _, _ in isRendering = false }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

/// 视频呈现层。**刻意不用 `AVPlayerLayer`**：它的内容既不参与 Liquid Glass 的
/// 背景采样（玻璃盖上去会是空的），也不进系统快照（上滑到多任务视图时封面会变成
/// 一块纯背景）。改成把解码帧的 IOSurface 直接塞进普通 CALayer 的 contents，两个
/// 问题一起消失，而且暂停时最后一帧天然留在层上，等于免费的冻结帧。
private final class MotionArtworkPlayerView: UIView {
    let videoLayer: CALayer = {
        let layer = CALayer()
        // resizeAspect 而不是 AspectFill：容器比例只要和视频差一点，Fill 就会裁掉
        // 边缘、看起来像被放大。竖版容器本来就是 3:4，用 Aspect 不会有黑边，却能
        // 保证画面范围和 Apple 一致。
        layer.contentsGravity = .resizeAspect
        layer.masksToBounds = true
        return layer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 尺寸变化由布局驱动，不要走隐式动画，否则拉伸头图会拖影。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct MotionArtworkPlayerLayer: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    let onRenderingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRenderingChange: onRenderingChange)
    }

    func makeUIView(context: Context) -> MotionArtworkPlayerView {
        let view = MotionArtworkPlayerView()
        view.backgroundColor = .clear
        context.coordinator.view = view
        context.coordinator.load(url)
        context.coordinator.setPlaying(isPlaying)
        return view
    }

    func updateUIView(_ uiView: MotionArtworkPlayerView, context: Context) {
        context.coordinator.onRenderingChange = onRenderingChange
        context.coordinator.load(url)
        context.coordinator.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ uiView: MotionArtworkPlayerView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        let player: AVQueuePlayer
        var onRenderingChange: (Bool) -> Void
        weak var view: MotionArtworkPlayerView?

        private var looper: AVPlayerLooper?
        private var itemObservation: NSKeyValueObservation?
        private var videoOutput: AVPlayerItemVideoOutput?
        private var displayLink: CADisplayLink?
        private var hasDeliveredFrame = false
        /// 必须强引用当前这帧。IOSurface 只是 pixel buffer 的一个视图，buffer 一
        /// 释放就会被输出的回收池收回复用，layer.contents 随即塌成空白——上滑到多
        /// 任务视图时封面"渐隐成纯色"就是这么来的。留住它，冻结帧才立得住。
        private var displayedBuffer: CVPixelBuffer?

        init(onRenderingChange: @escaping (Bool) -> Void) {
            self.onRenderingChange = onRenderingChange
            player = AVQueuePlayer()
            // 这些视频没有音轨（HLS variant 名里的 Anull），而且这里从不激活
            // AVAudioSession —— 一旦激活就会打断用户正在放的音乐。静音是双保险。
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        private var loadedURL: URL?

        func load(_ url: URL) {
            guard loadedURL != url else { return }
            loadedURL = url
            hasDeliveredFrame = false
            report(false)

            itemObservation?.invalidate()
            looper?.disableLooping()
            // AVPlayerLooper 负责无缝循环：它按模板不断续排队列项，比监听
            // AVPlayerItemDidPlayToEndTime 再 seek(.zero) 少一次可见的卡顿。
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))

            // 循环器会不断换 currentItem，视频输出必须跟着挂到新的那个上。
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                let item = player.currentItem
                Task { @MainActor [weak self] in
                    self?.attachVideoOutput(to: item)
                }
            }
        }

        private func attachVideoOutput(to item: AVPlayerItem?) {
            guard let item else { return }
            // IOSurface 属性是关键：拿到的 pixel buffer 才能直接当 layer.contents，
            // 省掉每帧一次 CIImage→CGImage 的软件转换。
            // IOSurface 属性写成空字典即可（要的就是"启用 IOSurface 支持"）。
            // 字面量在 Swift 6 下会被推断成非 Sendable 的 Any，显式标成
            // [String: Int] 这种具体 Sendable 类型可以既满足 API 又不触发告警。
            let surfaceProperties: [String: Int] = [:]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: surfaceProperties,
            ])
            item.add(output)
            videoOutput = output
        }

        func setPlaying(_ isPlaying: Bool) {
            if isPlaying {
                player.play()
                startDisplayLink()
            } else {
                // 停掉取帧即可：最后一帧留在 layer.contents 上，就是冻结帧。
                stopDisplayLink()
                player.pause()
            }
        }

        private func startDisplayLink() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(pullFrame(_:)))
            // 视频是 24fps，没必要按屏幕刷新率满速取帧。
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 24)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func pullFrame(_ link: CADisplayLink) {
            guard let output = videoOutput, let view else { return }
            let time = output.itemTime(forHostTime: link.targetTimestamp)
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                  let surface = CVPixelBufferGetIOSurface(buffer) else { return }
            displayedBuffer = buffer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.videoLayer.contents = surface.takeUnretainedValue()
            CATransaction.commit()
            if !hasDeliveredFrame {
                hasDeliveredFrame = true
                report(true)
            }
        }

        func tearDown() {
            stopDisplayLink()
            itemObservation?.invalidate()
            itemObservation = nil
            videoOutput = nil
            displayedBuffer = nil
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
        }

        /// 回调可能发生在 SwiftUI 的更新过程中（`updateUIView` 里就会调），直接改
        /// @State 会触发「Modifying state during view update」。推迟一拍再报。
        private func report(_ isRendering: Bool) {
            Task { @MainActor in
                onRenderingChange(isRendering)
            }
        }
    }
}
