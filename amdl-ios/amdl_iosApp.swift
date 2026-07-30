//
//  amdl_iosApp.swift
//  amdl-ios
//
//  Created by 梁杨峻玮 on 2026/7/4.
//

import SwiftUI
import SwiftData

@main
struct amdl_iosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // 启动时对一遍界面和存储：凭据可能在 App 没运行的时候过期了。
                    //
                    // 这里以前问的是门户"我这个账号被批准了没有"。没有账号可问了，
                    // 但**有一件事必须在用户动手之前知道**：手上这份 token 还能不能
                    // 用。它只活约十分钟，所以"上次用还好好的"完全不说明问题，而
                    // 没有这一下，用户会在第一次提交下载失败时才发现要重新登录。
                    AppleAuthStore.shared.refreshFromStore()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
