//
//  DownloadView.swift
//  amdl-ios
//
//  Created by 梁杨峻玮 on 2026/7/4.
//

import SwiftUI

extension JobType {
    var usesArtworkZoomTransition: Bool {
        switch self {
        case .song, .album, .playlist, .station:
            true
        case .artist:
            false
        }
    }

    var usesCollectionTrackPresentation: Bool {
        self == .playlist || self == .station
    }

    var usesArtworkMetadataPalette: Bool {
        self == .song || self == .album
    }
}

struct DownloadView: View {
    @Binding var navigationPath: [String]
    @Namespace private var artworkNavigationNamespace
    @State private var jobs: [Job] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastEventID: Int64 = 0
    @State private var actionRunner = JobActionRunner()

    private var activeJobs: [Job] {
        jobs.filter { $0.status == .queued || $0.status == .running }
    }

    private var completedJobs: [Job] {
        jobs.filter { $0.status == .completed }
    }

    private var inactiveJobs: [Job] {
        jobs.filter { $0.status == .failed || $0.status == .cancelled }
    }

    private var displayedJobs: [Job] {
        activeJobs + completedJobs + inactiveJobs
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .listRowBackground(Color.red.opacity(0.08))
                    }
                }

                if jobs.isEmpty && !isLoading && errorMessage == nil {
                    Section {
                        ContentUnavailableView(
                            "暂无下载任务",
                            systemImage: "arrow.down.circle",
                            description: Text("通过分享链接或首页搜索添加下载")
                        )
                        .listRowBackground(Color.clear)
                    }
                }

                jobsSection("正在下载", jobs: activeJobs)
                jobsSection("已完成", jobs: completedJobs)
                jobsSection("失败 / 已取消", jobs: inactiveJobs)
            }
            .pageLargeTitle("下载")
            .task {
                await runFeedLifecycle()
            }
            .refreshable {
                await load(showLoading: false)
            }
            .navigationDestination(for: String.self) { jobID in
                DownloadDetailDestination(
                    jobID: jobID,
                    initialJob: jobs.first { $0.id == jobID },
                    artworkNavigationNamespace: artworkNavigationNamespace,
                    onRestarted: { newJobID in navigationPath = [newJobID] }
                )
            }
            .jobActionPrompts(runner: actionRunner, onConfirmed: handle(outcome:))
            .swAlert()
        }
    }

    /// 动作成功之后总览列表要做的事。
    ///
    /// 取消和重新入队都**不**动本地的 `jobs`：总览 SSE 会推一条
    /// `download_upserted` 带着新状态回来，本地再改一遍就是和事件流抢方向盘。
    /// 用户不会盯着一行不动的列表 —— `actionRunner.inFlight` 让那一行在这期间
    /// 显示「正在停止…」。
    ///
    /// 删除是例外：HTTP 200 已经证明这条没了，本地直接摘掉。随后那条
    /// `download_deleted` 落到 `apply(_:)` 里也只是再 `removeAll` 一次，无害。
    private func handle(outcome: JobActionOutcome) {
        switch outcome {
        case let .deleted(jobID):
            jobs.removeAll { $0.id == jobID }
        case let .restarted(newJobID):
            SWAlertManager.shared.show(.success, message: "已重新提交为新任务")
            if let newJobID {
                navigationPath = [newJobID]
            }
        case .cancelling, .requeued:
            break
        }
    }

    @ViewBuilder
    private func jobsSection(_ title: String, jobs: [Job]) -> some View {
        if !jobs.isEmpty {
            Section(title) {
                ForEach(jobs) { job in
                    NavigationLink(value: job.id) {
                        DownloadJobRow(
                            job: job,
                            inFlightAction: actionRunner.action(forJobID: job.id),
                            artworkNavigationNamespace: artworkNavigationNamespace
                        )
                    }
                    .task(id: "large-artwork|\(job.id)|\(job.artworkURL ?? "")") {
                        await prefetchLargeArtwork(startingAt: job.id)
                    }
                    // allowsFullSwipe: false —— 最外侧那个按钮是「删除」，而删除
                    // 不可撤销且要先确认。让一次划到底就触发它，等于把确认框做成
                    // 误触之后才弹的东西。
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        ForEach(job.status.trailingSwipeActions) { action in
                            Button(role: action.isDestructive ? .destructive : nil) {
                                Task {
                                    if let outcome = await actionRunner.request(action, on: job) {
                                        handle(outcome: outcome)
                                    }
                                }
                            } label: {
                                Label(action.title, systemImage: action.symbolName)
                            }
                            .tint(action.isDestructive ? .red : .accentColor)
                        }
                    }
                }
            }
        }
    }

    private func runFeedLifecycle() async {
        await load(showLoading: true)
        await streamFeed()
    }

    private func load(showLoading: Bool) async {
        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading, !Task.isCancelled {
                isLoading = false
            }
        }

        do {
            let snapshot = try await DownloadsAPI.listDownloads()
            guard !Task.isCancelled else { return }
            jobs = snapshot.downloads
            for job in jobs where job.status.isActive {
                DownloadLiveActivityManager.shared.cacheArtworkForLiveActivity(from: job)
            }
            lastEventID = max(lastEventID, snapshot.lastEventID)
            errorMessage = nil
        } catch {
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    private func streamFeed() async {
        while !Task.isCancelled {
            do {
                let url = try DownloadsAPI.downloadsFeedWebSocketURL(lastEventID: lastEventID)
                let socket = await URLSession.shared.authorizedWebSocketTask(with: url)
                socket.resume()

                try await withTaskCancellationHandler {
                    while true {
                        let message = try await socket.receive()
                        guard case .string(let text) = message,
                              let feedMessage = DownloadsAPI.decodeFeedMessage(from: text) else {
                            continue
                        }
                        apply(feedMessage)
                    }
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await load(showLoading: false)
            }
        }
    }

    private func apply(_ message: DownloadFeedMessage) {
        switch message.type {
        case "download_upserted":
            guard let job = message.job else { return }
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            DownloadLiveActivityManager.shared.cacheArtworkForLiveActivity(from: job)
            if let eventID = message.eventID {
                lastEventID = max(lastEventID, eventID)
            }
        case "download_deleted":
            guard let jobID = message.jobID else { return }
            jobs.removeAll { $0.id == jobID }
        default:
            break
        }
    }

    private func prefetchLargeArtwork(startingAt jobID: String) async {
        let orderedJobs = displayedJobs
        guard let index = orderedJobs.firstIndex(where: { $0.id == jobID }) else { return }
        let end = min(index + 11, orderedJobs.endIndex)
        for job in orderedJobs[index..<end] {
            guard !Task.isCancelled else { return }
            await JobArtworkLoader.prefetch(
                job: job,
                pixelSize: JobArtworkLoader.heroPixelSize
            )
        }
    }
}

private struct DownloadJobRow: View {
    let job: Job
    /// 这一行上正在飞的动作。取消和重新开始的真实状态要等事件流回来，中间这段
    /// 空窗如果什么都不显示，用户会以为侧滑没生效。
    var inFlightAction: JobAction?
    let artworkNavigationNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName)
                    .font(.body)
                    .lineLimit(1)

                Text(inFlightAction?.inFlightTitle ?? job.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if job.status.isActive {
                    ThinProgressBar(progress: job.progress, tint: job.type.tint)
                }
            }

            Spacer()
            statusAccessory
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var artwork: some View {
        let artwork = JobArtworkView(job: job)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
            }

        if job.type.usesArtworkZoomTransition {
            artwork.matchedTransitionSource(id: job.id, in: artworkNavigationNamespace)
        } else {
            artwork
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch job.status {
        case .running, .queued:
            ProgressRing(progress: job.progress, tint: job.type.tint)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DownloadDetailDestination: View {
    let jobID: String
    let initialJob: Job?
    let artworkNavigationNamespace: Namespace.ID
    let onRestarted: (String) -> Void

    private var usesZoomTransition: Bool {
        initialJob?.type.usesArtworkZoomTransition == true
    }

    var body: some View {
        DownloadDetailView(
            jobID: jobID,
            initialJob: initialJob,
            usesZoomTransition: usesZoomTransition,
            onRestarted: onRestarted
        )
        .id(jobID)
        .modifier(
            DownloadZoomTransitionModifier(
                isEnabled: usesZoomTransition,
                sourceID: jobID,
                namespace: artworkNavigationNamespace
            )
        )
    }
}

private struct DownloadZoomTransitionModifier: ViewModifier {
    let isEnabled: Bool
    let sourceID: String
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}

#Preview {
    DownloadView(navigationPath: .constant([]))
}
