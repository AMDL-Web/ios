//
//  DownloadDetailView.swift
//  amdl-ios
//

import SwiftUI
import UIKit

struct DownloadDetailPalette {
    let background: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
}

struct DownloadDetailView: View {
    let jobID: String
    let initialJob: Job?
    var usesZoomTransition: Bool = false

    @State private var barFade = DownloadNavBarFadeHandle()
    @State private var barItemsVisible = true
    @State private var detail: DownloadDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastEventID: Int64 = 0
    @State private var presentedQualityDetails: AudioQualityPresentation.Details?
    @State private var speedTracker = TaskSpeedTracker()
    @AppStorage(MotionArtworkStyle.storageKey) private var motionStyleRaw = MotionArtworkStyle.square.rawValue

    private var motionStyle: MotionArtworkStyle {
        MotionArtworkStyle(rawValue: motionStyleRaw) ?? .square
    }

    /// 竖版出血版式只在该任务确实有 3:4 动态封面时启用；没有就退回方形卡片。
    private var tallHeaderURL: URL? {
        guard motionStyle == .tall, let job else { return nil }
        return job.motionArtworkVideoURL(style: .tall)
    }

    /// 竖版头图必须有个背景色来做底部渐变。动态配色是首选，但在加配色之前解析的
    /// 旧任务只有 URL 没有调色板 —— 那种情况退回静态封面那套，总比整个版式静默
    /// 失效强。
    private var tallHeaderPalette: DownloadDetailPalette? {
        guard tallHeaderURL != nil, let job else { return nil }
        return job.motionArtworkPalette(style: .tall) ?? palette
    }

    private var job: Job? {
        detail?.job ?? initialJob
    }

    private var items: [JobItem] {
        detail?.items ?? []
    }

    private var progress: Double {
        min(max(detail?.progress ?? job?.progress ?? 0, 0), 1)
    }

    private var hooks: [HookState] {
        detail?.hooks ?? []
    }

    private var appleMusicURL: URL? {
        guard let input = job?.input,
              let url = URL(string: input),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// 正在展示动态封面时改用它自己那套配色。每个资产的调色板差别很大（静态
    /// `598090` 配近黑、方形 `5c6786` 配近白、竖版 `05104b` 配浅色），拿静态那套
    /// 去配动态画面会得到深底深字 —— 这也是它和 Apple Music 观感对不上的原因。
    private var palette: DownloadDetailPalette? {
        guard let job, job.type.usesArtworkMetadataPalette else { return nil }
        if job.motionArtworkVideoURL(style: motionStyle) != nil,
           let motionPalette = job.motionArtworkPalette(style: motionStyle) {
            return motionPalette
        }
        guard let background = job.artworkBackgroundColor else {
            return nil
        }
        let primary = job.artworkPrimaryTextColor ?? .primary
        let secondary = job.artworkSecondaryTextColor ?? primary.opacity(0.8)
        return DownloadDetailPalette(
            background: background,
            primaryText: primary,
            secondaryText: secondary,
            tertiaryText: Color(hexRGB: job.artworkTextColor3) ?? secondary
        )
    }

    private var streamShouldClose: Bool {
        guard let job else { return true }
        return !job.status.isActive && !hooks.contains { $0.isActive }
    }

    var body: some View {
        ZStack {
            if job?.type == .song {
                DownloadSongDetailContent(
                    job: job,
                    items: items,
                    progress: progress,
                    downloadSpeed: speedTracker.downloadBytesPerSecond,
                    decryptSpeed: speedTracker.decryptBytesPerSecond,
                    errorMessage: errorMessage,
                    palette: palette,
                    presentedQualityDetails: $presentedQualityDetails
                )
            } else {
                DownloadTrackListView(
                    job: job,
                    tallHeaderURL: tallHeaderURL,
                    tallHeaderPalette: tallHeaderPalette,
                    items: items,
                    progress: progress,
                    downloadSpeed: speedTracker.downloadBytesPerSecond,
                    decryptSpeed: speedTracker.decryptBytesPerSecond,
                    isLoading: isLoading,
                    hasLoadedDetail: detail != nil,
                    errorMessage: errorMessage,
                    palette: palette,
                    presentedQualityDetails: $presentedQualityDetails
                )
            }
        }
        .background {
            if let palette {
                palette.background.ignoresSafeArea()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !usesZoomTransition || barItemsVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    if let appleMusicURL {
                        DownloadDetailLinkActions(taskURL: appleMusicURL)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(usesZoomTransition && !barItemsVisible)
        .background {
            if usesZoomTransition {
                DownloadNavBarFadeCoordinator(handle: barFade)
                    .frame(width: 0, height: 0)
            }
        }
        .onAppear(perform: configureNavigationBarFade)
        .task(id: jobID) {
            await runDetailLifecycle()
        }
        .alert(item: $presentedQualityDetails) { details in
            Alert(
                title: Text(details.title),
                message: Text(details.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private func configureNavigationBarFade() {
        guard usesZoomTransition else { return }
        barFade.show = {
            setBarItemsVisible(true)
        }
        barFade.hide = {
            setBarItemsVisible(false)
        }
    }

    private func setBarItemsVisible(_ visible: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            barItemsVisible = visible
        }
    }

    private func runDetailLifecycle() async {
        speedTracker.reset()
        if let cachedData = await DownloadDetailCache.shared.loadData(jobID: jobID),
           var cached = try? JSONDecoder().decode(DownloadDetail.self, from: cachedData) {
            if let initialJob {
                cached.job.preservePresentationMetadata(from: initialJob)
            }
            detail = cached
            speedTracker.update(with: cached.items)
            lastEventID = max(lastEventID, cached.lastEventID ?? 0)
        }
        let hasCache = detail != nil
        await load(showLoading: !hasCache)
        guard job != nil else { return }
        await streamEventsWhileActive()
    }

    private func streamEventsWhileActive() async {
        while !Task.isCancelled, !streamShouldClose {
            do {
                let url = try DownloadsAPI.eventsWebSocketURL(
                    jobID: jobID,
                    lastEventID: lastEventID
                )
                let socket = URLSession.shared.authorizedWebSocketTask(with: url)
                socket.resume()

                try await withTaskCancellationHandler {
                    while true {
                        let message = try await socket.receive()
                        guard case .string(let text) = message,
                              let event = DownloadsAPI.decodeEvent(from: text) else {
                            continue
                        }
                        guard event.id > lastEventID else { continue }
                        lastEventID = event.id
                        guard detail?.apply(event) == true else { continue }

                        // 每条推送落地后重算聚合速度，刷新频率即跟随推送频率。
                        if let detail {
                            speedTracker.update(with: detail.items)
                        }

                        if event.requiresDetailSnapshotRefresh {
                            await load(showLoading: false)
                        } else if let detail {
                            DownloadLiveActivityManager.shared.scheduleRefreshFromDetail(detail)
                        }

                        if streamShouldClose {
                            socket.cancel(with: .normalClosure, reason: nil)
                            return
                        }
                    }
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
                return
            } catch {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await load(showLoading: false)
            }
        }
    }

    private func load(showLoading: Bool) async {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == nil else {
            return
        }

        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading, !Task.isCancelled {
                isLoading = false
            }
        }

        do {
            var snapshot = try await DownloadsAPI.getDownload(id: jobID)
            guard !Task.isCancelled else { return }
            let snapshotEventID = snapshot.lastEventID ?? 0
            let currentEventID = max(lastEventID, detail?.lastEventID ?? 0)
            if detail == nil || snapshotEventID >= currentEventID {
                if let detail {
                    snapshot.preservePresentationMetadata(from: detail)
                } else if let initialJob {
                    snapshot.job.preservePresentationMetadata(from: initialJob)
                }
                detail = snapshot
                speedTracker.update(with: snapshot.items)
                await DownloadLiveActivityManager.shared.refreshFromDetail(snapshot)
                guard !Task.isCancelled else { return }
                lastEventID = max(lastEventID, snapshotEventID)
            }
            if let data = try? JSONEncoder().encode(snapshot) {
                await DownloadDetailCache.shared.storeData(data, jobID: jobID)
            }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else {
                return
            }
            if detail == nil {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct DownloadDetailLinkActions: View {
    let taskURL: URL

    var body: some View {
        ControlGroup {
            Link(destination: taskURL) {
                Image(systemName: "music.note")
                    .frame(width: 24.5)
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("在 Apple Music 中打开")

            Menu {
                Button(action: copyTaskLink) {
                    Label("复制链接", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("更多")
        }
    }

    private func copyTaskLink() {
        UIPasteboard.general.string = taskURL.absoluteString
    }
}

@MainActor
private final class DownloadNavBarFadeHandle {
    var show: (() -> Void)?
    var hide: (() -> Void)?
}

private struct DownloadNavBarFadeCoordinator: UIViewControllerRepresentable {
    let handle: DownloadNavBarFadeHandle

    func makeUIViewController(context: Context) -> FadeViewController {
        FadeViewController(handle: handle)
    }

    func updateUIViewController(_ viewController: FadeViewController, context: Context) {}

    final class FadeViewController: UIViewController {
        private let handle: DownloadNavBarFadeHandle

        init(handle: DownloadNavBarFadeHandle) {
            self.handle = handle
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            handle.show?()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            handle.hide?()
        }
    }
}

#Preview("详情 · 下载中") {
    NavigationStack {
        DownloadDetailView(
            jobID: "preview-running",
            initialJob: Job(
                id: "preview-running",
                input: "https://music.apple.com/cn/album/preview/1234567890",
                type: .album,
                storefront: "cn",
                title: "SHINSEI MOKUROKU",
                artworkURL: nil,
                force: false,
                status: .running,
                totalItems: 11,
                doneItems: 3,
                failedItems: 0,
                error: nil,
                createdAt: .now,
                updatedAt: .now
            )
        )
    }
}
