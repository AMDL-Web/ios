//
//  DownloadDetailView.swift
//  amdl-ios
//

import SwiftUI
import UIKit

struct DownloadDetailPalette: Equatable {
    let background: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
}

struct DownloadDetailView: View {
    let jobID: String
    let initialJob: Job?
    var usesZoomTransition: Bool = false
    /// 「重新开始」一个**已取消**的任务会得到一个新任务（新 id），这里把它交回给
    /// 导航栈的持有者，好让详情页跟着跳到新任务上，而不是留在那条已取消的上面。
    var onRestarted: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var actionRunner = JobActionRunner()
    /// 累加它就会重跑 `runDetailLifecycle()`（重拉快照 + 重连事件流）。
    /// 只有「终态任务被重新入队」需要它，原因见 `handle(outcome:)`。
    @State private var lifecycleGeneration = 0
    @State private var barFade = DownloadNavBarFadeHandle()
    @State private var barItemsVisible = true
    @State private var detail: DownloadDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastEventID: Int64 = 0
    @State private var presentedQualityDetails: AudioQualityPresentation.Details?
    @State private var isShowingInfo = false
    @State private var isShowingRealtimeSpeed = false
    @State private var speedTracker = TaskSpeedTracker()
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
        if job.motionArtworkVideoURL != nil, let motionPalette = job.motionArtworkPalette {
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

    /// 后端解析 input 之前，任务上只有一条链接：没有标题、没有曲目数、没有封面
    /// 配色，也没有逐曲清单。解析前后**是两份内容**，不是同一份内容长高了。
    ///
    /// 进了终态就不再算「等解析」：解析失败的任务永远等不到标题，它得照常显示自己
    /// 的错误，而不是停在另一份内容上。
    private var isAwaitingMetadata: Bool {
        guard let job else { return true }
        guard job.status.isActive else { return false }
        let hasTitle = !(job.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return !hasTitle && job.totalItems == 0
    }

    var body: some View {
        ZStack {
            detailContent
                // 元数据到达那一刻，标题从链接换成真标题（一行变两行）、`0/0` 变成
                // `0/48`、「暂无轨道明细」变成整张曲目表 —— 而封面配色也正好在同一次
                // 更新里从无到有。于是下面那条 `.animation(value: palette)` 把这次
                // 内容替换一并接管了：SwiftUI 找不到「两份内容」，只看见同一个视图的
                // 高度从 A 变成 B，就去补间这个差值。封面以下的一切在那半秒里连续
                // 滑动，两套版式还同时挂在屏幕上（`已完成 0/0` 和 `已完成 0/48` 相隔
                // 一行地一起显影）。
                //
                // 给两种状态各自的身份 + 纯不透明度过渡之后，就没有任何几何量可补间
                // 了：旧的那份在原地淡出，新的那份从第一帧起就待在自己的最终位置上
                // 淡入。ZStack 让两份重叠共存、谁都不参与对方的布局，所以淡入淡出还
                // 在，版式本身一个数都没动。
                .id(isAwaitingMetadata)
                .transition(.opacity)
        }
        .background {
            if let palette {
                palette.background.ignoresSafeArea()
            }
        }
        // 动态封面是后端异步回填的，详情页开着的时候它可能中途才到。到达时配色会
        // 从静态封面那套换成动态那套（例如 598090 → 5c6786），硬切会很突兀，所以
        // 让整棵子树的颜色插值过去，和封面本身的淡入同步。
        .animation(.easeInOut(duration: 0.5), value: palette)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !usesZoomTransition || barItemsVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    // 「详细信息」不依赖链接可用，所以这里跟着任务本身出现；
                    // input 不是 http(s) 时只是少掉 Apple Music 入口和复制链接。
                    if let job {
                        DownloadDetailLinkActions(
                            job: job,
                            taskURL: appleMusicURL,
                            runner: actionRunner,
                            showRealtimeSpeed: {
                                isShowingRealtimeSpeed = true
                            },
                            showInfo: { isShowingInfo = true },
                            onOutcome: handle(outcome:)
                        )
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
        .task(id: "\(jobID)|\(lifecycleGeneration)") {
            await runDetailLifecycle()
        }
        .sheet(isPresented: $isShowingInfo) {
            if let job {
                DownloadDetailInfoView(job: job, items: items, hooks: hooks)
            }
        }
        .sheet(isPresented: $isShowingRealtimeSpeed) {
            DownloadTaskSpeedView(speed: speedTracker.presentation)
        }
        .onChange(of: job?.status.isActive) { _, isActive in
            guard isActive != true else { return }
            isShowingRealtimeSpeed = false
            speedTracker.reset()
        }
        .alert(item: $presentedQualityDetails) { details in
            Alert(
                title: Text(details.title),
                message: Text(details.message),
                dismissButton: .default(Text("好"))
            )
        }
        .jobActionFailureAlert(runner: actionRunner)
        .swAlert()
    }

    /// 页面主体。原样从 `body` 里搬出来，只为让 `.id` / `.transition` 有个落点；
    /// 视图本身和它们收到的参数一个字都没改。
    @ViewBuilder
    private var detailContent: some View {
        if job?.type == .song {
            DownloadSongDetailContent(
                job: job,
                items: items,
                progress: progress,
                errorMessage: errorMessage,
                palette: palette,
                presentedQualityDetails: $presentedQualityDetails
            )
        } else {
            DownloadTrackListView(
                job: job,
                items: items,
                progress: progress,
                isLoading: isLoading,
                hasLoadedDetail: detail != nil,
                errorMessage: errorMessage,
                palette: palette,
                presentedQualityDetails: $presentedQualityDetails
            )
        }
    }

    /// 动作成功之后详情页要做的事。
    private func handle(outcome: JobActionOutcome) {
        switch outcome {
        case .deleted:
            // 200 已经证明这条没了，再留在页面上只会等来一个 404。
            dismiss()
        case let .restarted(newJobID):
            SWAlertManager.shared.show(.success, message: "已重新提交为新任务")
            if let newJobID {
                onRestarted?(newJobID)
            }
        case .cancelling:
            // 什么都不做：任务还是活跃的，事件流开着，`job_cancelled` 会把新状态送回来。
            break
        case .requeued:
            // 这一条**必须**重来一遍生命周期，别的都不用。
            //
            // `streamEventsWhileActive` 的循环条件是 `!streamShouldClose`，任务进终态
            // 就收工不再连了 —— 对 active → terminal 是对的，反过来就没救了：重试把一个
            // failed 的任务打回 queued，页面这边没有任何东西会告诉它。结果就是详情页
            // 一直显示「失败」、⋯ 菜单一直挂着「重新开始」，再点一次必得 409。
            // （实测过：本机后端上重试之后，菜单里那两个按钮原样不动。）
            //
            // 重新拉一次快照 + 重新连事件流，之后就又由事件流接管了。
            lifecycleGeneration += 1
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
            updateSpeedTracker(with: cached.items)
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
                let socket = await URLSession.shared.authorizedWebSocketTask(with: url)
                socket.resume()

                try await withTaskCancellationHandler {
                    while true {
                        let message = try await socket.receive()
                        guard case .string(let text) = message,
                              let event = DownloadsAPI.decodeEvent(from: text) else {
                            continue
                        }
                        guard event.id > lastEventID else { continue }
                        // 任务被删掉时后端会在这条流上补一块墓碑事件（`job_deleted`，
                        // 见 backend domain.go:428），随后这条流自己就结束了。别的设备
                        // 上删掉的任务靠它退出，不然这页会一直挂着一份再也不会更新的
                        // 快照，直到用户下拉刷新才撞上 404。
                        if event.type == "job_deleted" {
                            socket.cancel(with: .normalClosure, reason: nil)
                            dismiss()
                            return
                        }
                        lastEventID = event.id
                        guard detail?.apply(event) == true else { continue }
                        if let detail {
                            updateSpeedTracker(with: detail.items)
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
                updateSpeedTracker(with: snapshot.items)
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
            // 任务不在了就退出，别把 404 当成一次普通的刷新失败挂在页面上。
            // 后端这条 404 的错误体是 `{"error":"sql: no rows in result set"}`
            // ——一句没法给人看的话，所以是按状态码判，不是按文案判。
            if case .server(404, _, _)? = error as? DownloadsAPIError {
                dismiss()
                return
            }
            if detail == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 只在当前详情页生命周期内保留一小段趋势。关闭弹窗后继续更新这份临时内存，
    /// 再次打开可以直接续上；不会写入 UserDefaults、数据库或磁盘。
    private func updateSpeedTracker(with items: [JobItem]) {
        speedTracker.update(with: items)
    }
}

private struct DownloadDetailLinkActions: View {
    let job: Job
    let taskURL: URL?
    let runner: JobActionRunner
    let showRealtimeSpeed: () -> Void
    let showInfo: () -> Void
    let onOutcome: (JobActionOutcome) -> Void

    var body: some View {
        ControlGroup {
            if let taskURL {
                Link(destination: taskURL) {
                    Image(systemName: "music.note")
                        .frame(width: 24.5)
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("在 Apple Music 中打开")
            }

            Menu {
                if let taskURL {
                    Button {
                        UIPasteboard.general.string = taskURL.absoluteString
                    } label: {
                        Label("复制链接", systemImage: "doc.on.doc")
                    }
                }

                Button(action: showInfo) {
                    Label("详细信息", systemImage: "info.circle")
                }

                if job.status.isActive {
                    Button(action: showRealtimeSpeed) {
                        Label("实时速度显示", systemImage: "chart.xyaxis.line")
                    }
                }

                // 可用动作跟着 job.status 走，而 job 是详情页那份被事件流实时更新的
                // 快照 —— 任务在菜单开着的时候跑完，下次展开就没有「停止」了。
                let actions = job.status.availableActions
                if !actions.isEmpty {
                    Section {
                        ForEach(actions) { action in
                            Button(role: action.isDestructive ? .destructive : nil) {
                                Task {
                                    if let outcome = await runner.run(action, on: job) {
                                        onOutcome(outcome)
                                    }
                                }
                            } label: {
                                Label(action.title, systemImage: action.symbolName)
                            }
                            .disabled(runner.action(forJobID: job.id) != nil)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("更多")
        }
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
