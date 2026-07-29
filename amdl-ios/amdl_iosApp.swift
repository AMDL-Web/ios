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
                    // 启动时问一次门户"我现在是什么状态"。`GET /api/gw/me` 是
                    // pending 账号唯一调得通的接口，所以这是 App 在用户动手之前
                    // 就能知道"登录成功了但还没被批准"的唯一途径——否则用户要等到
                    // 第一次提交下载失败，才从一个 403 里去猜发生了什么。
                    guard AppleAuthStore.shared.isSignedIn else { return }
                    await AppleAuthStore.shared.refreshAccountStatus()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
