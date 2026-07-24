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

struct ContentView: View {
    @State private var selectedTab: AppTab = .home
    @State private var downloadNavigationPath: [String] = []

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
