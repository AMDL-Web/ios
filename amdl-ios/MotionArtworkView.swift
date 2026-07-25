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
/// 没有动态封面、未登录 Apple Music、开了「减弱动态效果」或低电量模式时整个视图
/// 不渲染任何东西，下面的 [JobArtworkView] 原样露出。
struct MotionArtworkView: View {
    let job: Job

    @State private var artwork: MotionArtworkStore.MotionArtwork?
    @State private var isRendering = false
    @State private var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var request: MotionArtworkStore.Request? {
        MotionArtworkStore.request(for: job)
    }

    /// 「减弱动态效果」是无障碍设置，低电量模式是用户的续航诉求，两者都应当让
    /// 封面老实待着不动。切到后台时也停，省得白白解码。
    private var shouldPlay: Bool {
        !reduceMotion && !isLowPowerMode && scenePhase == .active
    }

    var body: some View {
        Group {
            if let url = artwork?.video {
                MotionArtworkPlayerLayer(
                    url: url,
                    isPlaying: shouldPlay,
                    onRenderingChange: { isRendering = $0 }
                )
                // 首帧真正上屏前保持透明，避免静态封面被一块黑底闪一下盖住。
                .opacity(isRendering ? 1 : 0)
                .animation(.easeInOut(duration: 0.45), value: isRendering)
                .allowsHitTesting(false)
            }
        }
        .task(id: request?.key) {
            await resolve()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func resolve() async {
        guard let request else {
            artwork = nil
            return
        }
        // 视图身份可能被导航复用去展示另一个任务，先清掉上一个任务的动态封面，
        // 否则会短暂把上一张专辑的视频盖在这一张的静态封面上。
        artwork = MotionArtworkStore.shared.cached(for: request) ?? nil
        isRendering = artwork != nil && isRendering

        let resolved = await MotionArtworkStore.shared.motionArtwork(for: request)
        guard !Task.isCancelled else { return }
        artwork = resolved
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
