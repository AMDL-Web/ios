import ActivityKit
import Foundation

nonisolated struct DownloadActivityAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// single：显示任务名和平均进度；multiple：只显示活跃任务数量。
        var mode: String
        var jobID: String?
        var title: String
        /// 后端封面 URL 模板。App 被远程活动唤醒后下载到 App Group，APNs 不传图片数据。
        var artworkURL: String? = nil
        /// App 写完共享缓存后改变此值，确保 ActivityKit 立即重绘封面。
        var artworkRevision: String? = nil
        var status: String
        var progress: Double
        var activeCount: Int
        /// 后端任务事件游标，用于阻止 App 本地更新覆盖较新的 APNs 状态。
        var backendEventID: Int64? = nil
    }

    /// 固定聚合活动标识。网关始终只维护这一条全局下载活动。
    var gatewayID: String
}
