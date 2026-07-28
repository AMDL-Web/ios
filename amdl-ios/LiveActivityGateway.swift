import ActivityKit
import Foundation
import ImageIO
import UIKit

enum LiveActivityGatewayError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "iOS 网关地址无效"
        case .invalidResponse:
            "iOS 网关返回了无法解析的响应"
        case .server(let status):
            "iOS 网关请求失败（HTTP \(status)）"
        }
    }
}

enum LiveActivityGatewayAPI {
    /// 同 `DownloadsAPI.defaultBaseURLString`，走同一个域名，只是那一端把 `/apns`
    /// 前缀剥掉后转给 APNs 推送后端（`amdl-ios-gateway`），所以这里必须带上该前缀。
    ///
    /// 剥前缀的活儿从 Traefik 搬到了门户：以前是 `amdl-apns-strip` 这个 stripPrefix
    /// 中间件，现在是门户策略表里的 `/apns/*` 那几行。对 App 来说地址形状没变，
    /// **但那个 router 已经不存在了**——`amdl-ios-gateway` 现在只在内网，不经过门户
    /// 就没有任何路径能注册设备令牌，实时活动会静悄悄地再也不出现。
    static let defaultBaseURLString = "https://amdl.lyjw131.com/apns"
    private static let baseURLKey = "liveActivityGatewayBaseURL"
    private static let deviceIDKey = "liveActivityGatewayDeviceID"

    static var baseURLString: String {
        get {
            // 不再改写用户存下的地址：内置默认值已移除，填什么用什么。
            UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURLString
        }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: deviceIDKey)
        return created
    }

    static func registerPushToStartToken(
        _ token: String,
        activitiesEnabled: Bool,
        frequentPushesEnabled: Bool,
        activeActivityCount: Int
    ) async throws {
        try await post(
            path: "/v1/devices/\(deviceID)/push-to-start",
            body: TokenRequest(
                token: token,
                activitiesEnabled: activitiesEnabled,
                frequentPushesEnabled: frequentPushesEnabled,
                activeActivityCount: activeActivityCount
            )
        )
    }

    /// 注册标准 APNs device token。普通通知（例如下载完成横幅）只能用这个
    /// token 投递，与实时活动的 push-to-start / update token 是相互独立的凭据。
    static func registerNotificationToken(_ token: String) async throws {
        try await post(
            path: "/v1/devices/\(deviceID)/push-token",
            body: NotificationTokenRequest(token: token)
        )
    }

    static func registerActivityToken(activityID: String, token: String) async throws {
        try await post(
            path: "/v1/devices/\(deviceID)/activities",
            body: ActivityTokenRequest(activityID: activityID, token: token)
        )
    }

    /// 网关地址可以带路径前缀（反向代理下是 `https://<域名>/apns`），所以端点路径
    /// 要**追加**在它后面。早先这里直接 `components.path = path`，会把前缀整个
    ///覆盖掉，请求打到 `/v1/devices/...` 而不是 `/apns/v1/devices/...`。
    private static func makeURL(path: String) -> URL? {
        guard !baseURLString.isEmpty, var components = URLComponents(string: baseURLString) else {
            return nil
        }
        var prefix = components.path
        while prefix.hasSuffix("/") {
            prefix.removeLast()
        }
        components.path = prefix + path
        return components.url
    }

    static func activityStatus() async throws -> ActivityStatusResponse {
        guard let url = makeURL(path: "/health") else {
            throw LiveActivityGatewayError.invalidURL
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, httpResponse) = try await PortalHTTP.send(request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LiveActivityGatewayError.server(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(ActivityStatusResponse.self, from: data)
    }

    private static func post<T: Encodable>(path: String, body: T) async throws {
        guard let url = makeURL(path: path) else {
            throw LiveActivityGatewayError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        // 必须走 PortalHTTP：门户是这条路唯一的入口（`/apns/*` 转发给
        // amdl-ios-gateway），而且它靠请求上的会话来断言这台设备属于谁——
        // 没有凭据就注册不上，注册不上就再也收不到实时活动，而且**没有任何报错**。
        let (_, httpResponse) = try await PortalHTTP.send(request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LiveActivityGatewayError.server(httpResponse.statusCode)
        }
    }
}

struct ActivityStatusResponse: Decodable {
    let initialized: Bool
    let activeDownloads: Int

    enum CodingKeys: String, CodingKey {
        case initialized
        case activeDownloads = "active_downloads"
    }
}

private struct TokenRequest: Encodable {
    let token: String
    let activitiesEnabled: Bool
    let frequentPushesEnabled: Bool
    let activeActivityCount: Int

    enum CodingKeys: String, CodingKey {
        case token
        case activitiesEnabled = "activities_enabled"
        case frequentPushesEnabled = "frequent_pushes_enabled"
        case activeActivityCount = "active_activity_count"
    }
}

private struct NotificationTokenRequest: Encodable {
    let token: String
}

private struct ActivityTokenRequest: Encodable {
    let activityID: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case activityID = "activity_id"
        case token
    }
}

@MainActor
final class DownloadLiveActivityManager {
    static let shared = DownloadLiveActivityManager()

    private var didStart = false
    private var isReconciling = false
    private var pushToStartTask: Task<Void, Never>?
    private var pushRegistrationTask: Task<Void, Never>?
    private var activityDiscoveryTask: Task<Void, Never>?
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var activityRegistrationTasks: [String: Task<Void, Never>] = [:]
    private var contentTasks: [String: Task<Void, Never>] = [:]
    private var artworkTasks: [String: Task<Void, Never>] = [:]
    private var artworkTaskURLs: [String: String] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var artworkStoreTasks: [String: Task<Void, Never>] = [:]
    private var pendingLocalDetails: [String: DownloadDetail] = [:]
    private var localRefreshTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func start() {
        guard !didStart else { return }
        didStart = true
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivity] 用户未启用实时活动")
            return
        }

        for activity in Activity<DownloadActivityAttributes>.activities {
            observe(activity)
        }

        Task { [weak self] in
            await self?.reconcileWithGateway()
        }

        pushToStartTask = Task { [weak self] in
            for await tokenData in Activity<DownloadActivityAttributes>.pushToStartTokenUpdates {
                guard !Task.isCancelled else { return }
                let token = tokenData.hexString
                self?.pushRegistrationTask?.cancel()
                self?.pushRegistrationTask = Task { [weak self] in
                    await self?.retryRegistration(label: "push-to-start token") {
                        let authorization = ActivityAuthorizationInfo()
                        try await LiveActivityGatewayAPI.registerPushToStartToken(
                            token,
                            activitiesEnabled: authorization.areActivitiesEnabled,
                            frequentPushesEnabled: authorization.frequentPushesEnabled,
                            activeActivityCount: Activity<DownloadActivityAttributes>.activities.count
                        )
                    }
                }
                guard self != nil else { return }
            }
        }

        activityDiscoveryTask = Task { [weak self] in
            for await activity in Activity<DownloadActivityAttributes>.activityUpdates {
                guard !Task.isCancelled else { return }
                self?.observe(activity)
            }
        }
    }

    func reconcileWithGateway() async {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        do {
            let status = try await LiveActivityGatewayAPI.activityStatus()
            let activities = Activity<DownloadActivityAttributes>.activities
            if status.activeDownloads > 0 {
                // 前台对账是可靠的"App 醒着"时机；顺手把活跃任务封面预取
                // 落盘，之后多→单切换的远程推送即使不唤醒 App 也能出图。
                prefetchArtworkForActiveJobs()
            }
            guard status.initialized else {
                await refreshExistingActivities(activities)
                return
            }

            if status.activeDownloads == 0 {
                for activity in activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    tokenTasks[activity.id]?.cancel()
                    tokenTasks[activity.id] = nil
                    activityRegistrationTasks[activity.id]?.cancel()
                    activityRegistrationTasks[activity.id] = nil
                    contentTasks[activity.id]?.cancel()
                    contentTasks[activity.id] = nil
                    artworkTasks[activity.id]?.cancel()
                    artworkTasks[activity.id] = nil
                    artworkTaskURLs[activity.id] = nil
                }
                if !activities.isEmpty {
                    print("[LiveActivity] 已清理 \(activities.count) 条无后端任务的残留活动")
                }
                return
            }

            if !activities.isEmpty {
                await refreshExistingActivities(activities)
                return
            }

            // APNs 接受 push-to-start 后，系统仍可能因为启动预算而延迟或丢弃。
            // 给远程启动留出时间；App 位于前台且仍无活动时，再进行本地兜底。
            try await Task.sleep(for: .seconds(3))
            guard Activity<DownloadActivityAttributes>.activities.isEmpty else { return }
            let refreshedStatus = try await LiveActivityGatewayAPI.activityStatus()
            guard refreshedStatus.initialized, refreshedStatus.activeDownloads > 0 else { return }

            let state = DownloadActivityAttributes.ContentState(
                mode: "multiple",
                jobID: nil,
                title: "下载任务",
                status: "running",
                progress: 0,
                activeCount: refreshedStatus.activeDownloads
            )
            let activity = try Activity.request(
                attributes: DownloadActivityAttributes(gatewayID: "amdl-downloads"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: .token
            )
            observe(activity)
            print("[LiveActivity] push-to-start 未落地，已创建本地兜底活动：\(activity.id)")
        } catch {
            // 网关不可达时不能推断任务已经结束，但 App 仍可直接从下载后端
            // 校准现有活动，不必依赖 APNs 或网关健康检查。
            await refreshExistingActivities(Activity<DownloadActivityAttributes>.activities)
            print("[LiveActivity] 跳过网关状态核对，已尝试本地校准：\(error)")
        }
    }

    func refreshFromDetail(_ detail: DownloadDetail) async {
        for activity in Activity<DownloadActivityAttributes>.activities
        where activity.content.state.jobID == detail.job.id {
            await update(activity, from: detail)
        }
    }

    func scheduleRefreshFromDetail(_ detail: DownloadDetail) {
        let jobID = detail.job.id
        if let pending = pendingLocalDetails[jobID],
           let pendingEventID = pending.lastEventID {
            guard let incomingEventID = detail.lastEventID,
                  incomingEventID >= pendingEventID else { return }
        }
        pendingLocalDetails[jobID] = detail
        guard localRefreshTasks[jobID] == nil else { return }

        localRefreshTasks[jobID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self else { return }
            let latest = pendingLocalDetails.removeValue(forKey: jobID)
            localRefreshTasks[jobID] = nil
            if let latest {
                await refreshFromDetail(latest)
            }
        }
    }

    /// 总览拿到任务的封面后立即写入 App Group。调用方在初次加载时只传活跃
    /// 任务，但实时推送的终态更新也会经过这里，覆盖“封面与完成态同时到达”的
    /// 快任务。下载不绑定某一条 Activity 的生命周期，因此状态切换或活动结束时
    /// 不会连带取消，Widget 能稳定读到与 App 概览一致的封面。
    func cacheArtworkForLiveActivity(from job: Job) {
        guard let template = job.artworkURL,
              !template.isEmpty,
              !LiveActivityArtworkStore.contains(template) else {
            return
        }

        Task { [weak self] in
            await self?.fetchArtworkIntoStore(template)
        }
    }

    private func refreshExistingActivities(
        _ activities: [Activity<DownloadActivityAttributes>]
    ) async {
        var activeJobs: [Job]?

        for activity in activities {
            let state = activity.content.state
            if state.mode == "single", let jobID = state.jobID, !jobID.isEmpty {
                do {
                    let detail = try await DownloadsAPI.getDownload(id: jobID)
                    await update(activity, from: detail)
                    continue
                } catch {
                    print("[LiveActivity] 前台校准任务 \(jobID) 失败：\(error)")
                }
            }

            do {
                if activeJobs == nil {
                    let snapshot = try await DownloadsAPI.listDownloads()
                    activeJobs = snapshot.downloads.filter { $0.status.isActive }
                }
                guard let activeJobs else { continue }
                if activeJobs.count == 1, let job = activeJobs.first {
                    let detail = try await DownloadsAPI.getDownload(id: job.id)
                    await update(activity, from: detail)
                } else if activeJobs.count > 1 {
                    var refreshed = state
                    refreshed.mode = "multiple"
                    refreshed.jobID = nil
                    refreshed.title = "多个下载任务正在运行"
                    refreshed.artworkURL = nil
                    refreshed.artworkRevision = nil
                    refreshed.status = "running"
                    refreshed.progress = 0
                    refreshed.activeCount = activeJobs.count
                    refreshed.backendEventID = nil
                    let content = ActivityContent(
                        state: refreshed,
                        staleDate: activity.content.staleDate
                    )
                    await Self.updateActivity(id: activity.id, content: content)
                    print("[LiveActivity] 已用 App 数据校准多任务状态")
                }
            } catch {
                print("[LiveActivity] 前台校准活动失败：\(error)")
            }
        }
    }

    private func update(
        _ activity: Activity<DownloadActivityAttributes>,
        from detail: DownloadDetail
    ) async {
        var state = activity.content.state
        if state.jobID == detail.job.id, let currentEventID = state.backendEventID {
            guard let incomingEventID = detail.lastEventID else {
                print("[LiveActivity] 忽略没有事件版本的 App 任务数据")
                return
            }
            if incomingEventID < currentEventID {
                print("[LiveActivity] 忽略旧的 App 任务数据：\(incomingEventID) < \(currentEventID)")
                return
            }
        }
        state.mode = "single"
        state.jobID = detail.job.id
        if let title = detail.job.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            state.title = title
        }
        if let artworkURL = detail.job.artworkURL, !artworkURL.isEmpty {
            state.artworkURL = artworkURL
        }
        state.status = detail.job.status.rawValue
        state.progress = min(max(detail.progress, 0), 1)
        state.activeCount = detail.job.status.isActive ? 1 : 0
        state.backendEventID = detail.lastEventID
        let content = ActivityContent(state: state, staleDate: activity.content.staleDate)
        await Self.updateActivity(id: activity.id, content: content)
        scheduleArtwork(for: activity, content: content)
        print("[LiveActivity] 已用 App 任务数据校准进度：\(Int(state.progress * 100))%")
    }

    private func observe(_ activity: Activity<DownloadActivityAttributes>) {
        observeUpdateToken(for: activity)
        observeArtwork(for: activity)
    }

    private func observeUpdateToken(for activity: Activity<DownloadActivityAttributes>) {
        let activityID = activity.id
        guard tokenTasks[activityID] == nil else { return }
        tokenTasks[activityID] = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                let token = tokenData.hexString
                self?.activityRegistrationTasks[activityID]?.cancel()
                self?.activityRegistrationTasks[activityID] = Task { [weak self] in
                    await self?.retryRegistration(label: "活动更新 token：\(activityID)") {
                        try await LiveActivityGatewayAPI.registerActivityToken(
                            activityID: activityID,
                            token: token
                        )
                    }
                }
            }
            self?.activityRegistrationTasks[activityID]?.cancel()
            self?.activityRegistrationTasks[activityID] = nil
            self?.tokenTasks[activityID] = nil
        }
    }

    private func observeArtwork(for activity: Activity<DownloadActivityAttributes>) {
        let activityID = activity.id
        guard contentTasks[activityID] == nil else { return }
        contentTasks[activityID] = Task { [weak self] in
            guard let self else { return }
            scheduleArtwork(for: activity, content: activity.content)
            for await content in activity.contentUpdates {
                guard !Task.isCancelled else { return }
                scheduleArtwork(for: activity, content: content)
            }
            artworkTasks[activityID]?.cancel()
            artworkTasks[activityID] = nil
            artworkTaskURLs[activityID] = nil
            contentTasks[activityID] = nil
        }
    }

    private func scheduleArtwork(
        for activity: Activity<DownloadActivityAttributes>,
        content: ActivityContent<DownloadActivityAttributes.ContentState>
    ) {
        let activityID = activity.id
        guard content.state.mode == "single" else {
            artworkTasks[activityID]?.cancel()
            artworkTasks[activityID] = nil
            artworkTaskURLs[activityID] = nil
            // 多任务模式自身不展示封面，但随时可能切回单任务；趁现在还能
            // 跑代码，把所有活跃任务的封面预取进共享存储。
            prefetchArtworkForActiveJobs()
            return
        }

        if let template = content.state.artworkURL, !template.isEmpty {
            if LiveActivityArtworkStore.contains(template) {
                return
            }
            startArtworkTask(
                key: "url:\(template)",
                activityID: activityID
            ) { [weak self] in
                await self?.downloadArtwork(
                    template,
                    jobID: content.state.jobID,
                    for: activity
                )
            }
            return
        }

        guard let jobID = content.state.jobID, !jobID.isEmpty else {
            return
        }
        startArtworkTask(key: "job:\(jobID)", activityID: activityID) { [weak self] in
            await self?.resolveAndDownloadArtwork(jobID: jobID, for: activity)
        }
    }

    private func startArtworkTask(
        key: String,
        activityID: String,
        operation: @escaping () async -> Void
    ) {
        if artworkTaskURLs[activityID] == key, artworkTasks[activityID] != nil {
            return
        }
        artworkTasks[activityID]?.cancel()
        artworkTaskURLs[activityID] = key
        artworkTasks[activityID] = Task { [weak self] in
            await operation()
            guard self?.artworkTaskURLs[activityID] == key else { return }
            self?.artworkTasks[activityID] = nil
            self?.artworkTaskURLs[activityID] = nil
        }
    }

    private func resolveAndDownloadArtwork(
        jobID: String,
        for activity: Activity<DownloadActivityAttributes>
    ) async {
        var delay: Duration = .milliseconds(400)
        for _ in 0..<8 {
            guard !Task.isCancelled else { return }
            do {
                let detail = try await DownloadsAPI.getDownload(id: jobID)
                if let template = detail.job.artworkURL, !template.isEmpty {
                    print("[LiveActivity] 已从后端取得封面地址")
                    await downloadArtwork(template, jobID: jobID, for: activity)
                    return
                }
                if !detail.job.status.isActive {
                    return
                }
            } catch {
                print("[LiveActivity] 获取任务封面地址失败，将重试：\(error)")
            }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            delay = min(delay * 2, .seconds(3))
        }
        print("[LiveActivity] 后端暂未提供封面地址")
    }

    private func downloadArtwork(
        _ template: String,
        jobID: String?,
        for activity: Activity<DownloadActivityAttributes>
    ) async {
        await fetchArtworkIntoStore(template)
        guard LiveActivityArtworkStore.contains(template) else { return }
        await refreshArtwork(template, jobID: jobID, for: activity)
    }

    /// 只把封面下载进共享存储，不触碰任何活动内容。除了正常的活动封面
    /// 下载外，也供预取使用。
    private func fetchArtworkIntoStore(_ template: String) async {
        guard !LiveActivityArtworkStore.contains(template) else { return }
        if let task = artworkStoreTasks[template] {
            await task.value
            return
        }

        // 实际下载由管理器持有的独立任务执行，不继承某一条 Activity 观察任务
        // 的取消状态；同一模板的所有调用合并为一次请求。
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await performArtworkFetch(template)
        }
        artworkStoreTasks[template] = task
        await task.value
        artworkStoreTasks[template] = nil
    }

    private func performArtworkFetch(_ template: String) async {
        guard !LiveActivityArtworkStore.contains(template) else { return }
        guard let url = LiveActivityArtworkStore.resolvedRemoteURL(from: template) else {
            print("[LiveActivity] 无效封面地址：\(template)")
            return
        }
        do {
            print("[LiveActivity] 开始下载高清封面")
            var request = URLRequest(authorizedURL: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let artworkData = Self.preparedArtworkData(from: data)
            else {
                print("[LiveActivity] 下载封面失败：响应或图片无效")
                return
            }
            try LiveActivityArtworkStore.store(artworkData, for: template)
        } catch is CancellationError {
            return
        } catch {
            print("[LiveActivity] 下载或缓存封面失败：\(error)")
        }
    }

    /// 预取所有活跃任务的封面。多任务模式没有 per-job 详情流，多→单切换
    /// 的那条远程推送也不会唤醒 App——如果目标任务的封面文件不在共享存储
    /// 里，Widget 只能一直渲染占位符。趁 App 还醒着（前台对账、或多任务
    /// 状态更新到达）把每个活跃任务的封面提前落盘，切换时第一帧就能出图。
    func prefetchArtworkForActiveJobs() {
        guard prefetchTask == nil else { return }
        prefetchTask = Task { [weak self] in
            defer { self?.prefetchTask = nil }
            do {
                let snapshot = try await DownloadsAPI.listDownloads()
                for job in snapshot.downloads where job.status.isActive {
                    guard !Task.isCancelled else { return }
                    if let template = job.artworkURL, !template.isEmpty {
                        await self?.fetchArtworkIntoStore(template)
                    }
                }
            } catch {
                print("[LiveActivity] 预取活跃任务封面失败：\(error)")
            }
        }
    }

    private func refreshArtwork(
        _ template: String,
        jobID: String?,
        for activity: Activity<DownloadActivityAttributes>
    ) async {
        let current = activity.content
        guard current.state.mode == "single",
              jobID == nil || current.state.jobID == jobID
        else { return }
        var state = current.state
        state.artworkURL = template
        state.artworkRevision = UUID().uuidString
        await Self.updateActivity(
            id: activity.id,
            content: ActivityContent(state: state, staleDate: current.staleDate)
        )
        print("[LiveActivity] 已缓存并刷新高清封面")
    }

    /// `Activity` is a reference type whose ActivityKit update method leaves the
    /// current actor. Resolve it inside a nonisolated operation so the manager's
    /// MainActor-owned reference never crosses that boundary.
    private nonisolated static func updateActivity(
        id: String,
        content: ActivityContent<DownloadActivityAttributes.ContentState>
    ) async {
        guard let activity = Activity<DownloadActivityAttributes>.activities.first(where: {
            $0.id == id
        }) else { return }
        await activity.update(content)
    }

    private static func preparedArtworkData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
           max(width.intValue, height.intValue) <= 512 {
            // Apple Music artwork endpoint already returned a display-sized JPEG.
            // Preserve its original encoding instead of introducing another lossy pass.
            return data
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 384,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.96)
    }

    private func retryRegistration(
        label: String,
        operation: @escaping () async throws -> Void
    ) async {
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                try await operation()
                print("[LiveActivity] 已注册 \(label)")
                return
            } catch {
                print("[LiveActivity] 注册 \(label) 失败，将重试：\(error)")
            }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            delay = min(delay * 2, .seconds(60))
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
