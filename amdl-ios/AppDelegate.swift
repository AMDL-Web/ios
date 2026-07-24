//
//  AppDelegate.swift
//  amdl-ios
//
//  Created by OpenAI on 2026/7/5.
//

import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        Task { @MainActor in
            // push-to-start token 不依赖先创建 Activity；冷启动和 APNs 远程
            // 启动唤醒都从这里建立监听，并把后续 update token 回传给网关。
            DownloadLiveActivityManager.shared.start()
        }

        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound])
                print("[Push] 通知权限: \(granted ? "已授权" : "被拒绝")")

                guard granted else { return }
                await MainActor.run {
                    application.registerForRemoteNotifications()
                }
            } catch {
                print("[Push] 请求通知权限失败: \(error)")
            }
        }

        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { @MainActor in
            await DownloadLiveActivityManager.shared.reconcileWithGateway()
        }
    }

    // MARK: - 远程推送注册

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[Push] Device Token: \(token)")
        // TODO: 把 token POST 到自己的服务端保存
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[Push] 注册远程推送失败: \(error)")
    }

    // MARK: - 通知接收

    // App 在前台时也弹出横幅
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    // 用户点击通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        print("[Push] 用户点击通知: \(response.notification.request.content.userInfo)")
    }

    // 静默推送（payload 带 "content-available": 1，需要 remote-notification 后台模式）
    // nonisolated：userInfo 不是 Sendable，不能跨进 MainActor；这里只读不碰 UI。
    nonisolated func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        print("[Push] 收到静默推送: \(userInfo)")
        return .newData
    }
}
