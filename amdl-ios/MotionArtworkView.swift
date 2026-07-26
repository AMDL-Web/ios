//
//  MotionArtworkView.swift
//  amdl-ios
//

import AVFoundation
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
    /// 只有方形模式才在静态封面上叠这一层；竖版模式走 [MotionArtworkTallHeader]。
    var style: MotionArtworkStyle = .square

    var body: some View {
        if style == .square, let url = job.motionArtworkVideoURL(style: .square) {
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

/// 承载 `AVPlayerLayer` 的 UIView —— 用 `layerClass` 而不是自己加一层 sublayer，
/// 这样图层尺寸由 Auto Layout 直接驱动，不需要在 `layoutSubviews` 里手动同步 frame。
private final class MotionArtworkPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass 已经声明为 AVPlayerLayer，这里必然成立。
        layer as! AVPlayerLayer
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
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = context.coordinator.player
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

        private var looper: AVPlayerLooper?
        private var observation: NSKeyValueObservation?
        private var loadedURL: URL?

        init(onRenderingChange: @escaping (Bool) -> Void) {
            self.onRenderingChange = onRenderingChange
            player = AVQueuePlayer()
            // 这些视频没有音轨（HLS variant 名里的 Anull），而且这里从不激活
            // AVAudioSession —— 一旦激活就会打断用户正在放的音乐。静音是双保险。
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        func load(_ url: URL) {
            guard loadedURL != url else { return }
            loadedURL = url
            report(false)

            observation?.invalidate()
            looper?.disableLooping()
            // AVPlayerLooper 负责无缝循环：它按模板不断续排队列项，比监听
            // AVPlayerItemDidPlayToEndTime 再 seek(.zero) 少一次可见的卡顿。
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))

            observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let isPlaying = player.timeControlStatus == .playing
                Task { @MainActor [weak self] in
                    self?.report(isPlaying)
                }
            }
        }

        func setPlaying(_ isPlaying: Bool) {
            if isPlaying {
                player.play()
            } else {
                player.pause()
            }
        }

        func tearDown() {
            observation?.invalidate()
            observation = nil
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
