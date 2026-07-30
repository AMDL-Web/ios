//
//  AppDelegate.swift
//  amdl-ios
//
//  Created by OpenAI on 2026/7/5.
//

import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private var pushTokenTask: Task<Void, Never>?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 必须在任何人读网关地址之前跑：旧版本把它单独存在 standard defaults 里，
        // 现在它由门户地址派生。晚一步 `DownloadLiveActivityManager.start()` 就会
        // 拿着未迁移的地址去注册 token。
        BackendEndpoint.migrateLegacyGatewayBaseURL()

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
        // 分享扩展问不到 MusicKit，只能读主 App 抄进钥匙串的那份 media user token。
        // 每次进前台刷新一次，「装上 App 之后只用分享面板」的用法才拿得到令牌。
        // 和上面那次对账分开起 Task：网关不通时它会卡住好几秒，令牌刷新不该陪等。
        Task { @MainActor in
            await AppleMusicTokenService.refreshSharedToken()
        }
    }

    // MARK: - 远程推送注册

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[Push] Device Token: \(token)")
        // 网关用这个 token 推送下载完成通知。系统每次启动都会重新回调，所以
        // 注册失败可以留给下一次启动；这里只做有限次退避重试。
        pushTokenTask?.cancel()
        pushTokenTask = Task { await Self.registerPushToken(token) }
    }

    private static func registerPushToken(_ token: String) async {
        var delay: Duration = .seconds(1)
        for attempt in 0..<6 {
            guard !Task.isCancelled else { return }
            do {
                try await LiveActivityGatewayAPI.registerNotificationToken(token)
                print("[Push] 已向网关注册通知 token")
                return
            } catch {
                print("[Push] 注册通知 token 失败（第 \(attempt + 1) 次）：\(error)")
            }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            delay = min(delay * 2, .seconds(30))
        }
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
        let userInfo = response.notification.request.content.userInfo
        print("[Push] 用户点击通知: \(userInfo)")

        guard let jobID = Self.jobID(fromNotificationUserInfo: userInfo) else { return }
        // 只登记目标，导航和「拉起 Emby」都由 ContentView 做：这个回调在冷启动时
        // 比根视图还早，那时本 App 自己都还没 active —— 直接推路径没人接得住，
        // 直接 UIApplication.open 也会被系统忽略，通知只会把自己打开而已。
        PendingDownloadRoute.shared.route(
            toJob: jobID,
            emby: Self.embyDeepLink(fromNotificationUserInfo: userInfo)
        )
    }

    /// 网关在专辑任务完成时放进 payload 的 `emby_deep_link`
    /// （amdl-ios-gateway `alertPayload`），形如
    /// `emby://items?serverId=<id>&itemId=<id>`。
    ///
    /// 只认 `emby` 这一个 scheme：这个值来自推送负载，照单全收就等于让任何能发到
    /// 这台设备的推送指定一个要打开的 URL。
    static func embyDeepLink(fromNotificationUserInfo userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo["emby_deep_link"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "emby"
        else {
            return nil
        }
        return url
    }

    /// 网关的完成通知在 payload 顶层带 `job_id`（amdl-ios-gateway `alertPayload`），
    /// 通知服务扩展换封面时也是照它分会话的，所以这是点击路由唯一的依据。
    static func jobID(fromNotificationUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let raw = userInfo["job_id"] as? String else { return nil }
        let jobID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return jobID.isEmpty ? nil : jobID
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
