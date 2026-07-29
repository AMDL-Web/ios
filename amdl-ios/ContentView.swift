//
//  ContentView.swift
//  amdl-ios
//
//  Created by 梁杨峻玮 on 2026/7/4.
//

import SwiftUI
import SwiftData

private enum AppTab: Hashable {
    case home
    case downloads
    case shazam
    case settings
}

/// 通知点击到达时根视图不一定存在：冷启动的 `didReceive` 在 `ContentView` 之前就跑
/// 完了，那时改导航状态没有任何东西接得住，跳转会被静默丢弃。AppDelegate 把目标存
/// 进这里，根视图一能导航就取走。
///
/// 实时活动的点击不走这条路——系统把 `widgetURL` 投递成 `amdl://download/<jobID>`，
/// `onOpenURL` 本来就负责冷启动那一份。两条路最后都汇进 `showDownloads(jobID:)`。
@MainActor
@Observable
final class PendingDownloadRoute {
    static let shared = PendingDownloadRoute()

    private(set) var jobID: String?

    private init() {}

    func route(toJob jobID: String) {
        self.jobID = jobID
    }

    /// 取走并清空，所以同一次点击只会导航一次。
    func take() -> String? {
        defer { jobID = nil }
        return jobID
    }
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .home
    @State private var downloadNavigationPath: [String] = []
    private let pendingRoute = PendingDownloadRoute.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("主页", systemImage: "house.fill", value: AppTab.home) {
                HomeView(onSubmitted: showDownloads)
            }

            Tab("下载", systemImage: "arrow.down.circle.fill", value: AppTab.downloads) {
                DownloadView(navigationPath: $downloadNavigationPath)
            }

            Tab("识曲", systemImage: "waveform.circle.fill", value: AppTab.shazam) {
                ShazamView()
            }

            Tab("配置", systemImage: "gearshape.fill", value: AppTab.settings) {
                RadioView()
            }
        }
        .onOpenURL(perform: handleOpenURL)
        // `initial: true` 是冷启动那一半：点击早于本视图时值已经在里面了，光等
        // 变化永远等不到。热启动走的是 `@Observable` 的变化通知。
        .onChange(of: pendingRoute.jobID, initial: true) { _, _ in
            guard let jobID = pendingRoute.take() else { return }
            showDownloads(jobID: jobID)
        }
    }

    private func showDownloads(jobID: String?) {
        selectedTab = .downloads
        if let jobID, !jobID.isEmpty {
            downloadNavigationPath = [jobID]
        } else {
            downloadNavigationPath = []
        }
    }

    private func handleOpenURL(_ url: URL) {
        selectedTab = .downloads
        guard url.scheme == "amdl", url.host == "download",
              let jobID = url.pathComponents.dropFirst().first,
              !jobID.isEmpty
        else {
            downloadNavigationPath = []
            return
        }
        downloadNavigationPath = [jobID]
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
