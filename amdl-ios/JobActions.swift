//
//  JobActions.swift
//  amdl-ios
//
//  任务管理动作（停止 / 重新开始 / 删除）：可用性推导、网络调用、错误措辞。
//

import Foundation
import SwiftUI

// MARK: - 动作

/// 一个任务管理动作。
///
/// `retry` 和 `restart` 对用户是同一个按钮（「重新开始」），底下走的却是两条完全
/// 不同的路 —— 原因见 `JobStatus.availableActions` 上那段注释。
enum JobAction: String, Identifiable, Hashable, CaseIterable, Sendable {
    /// `POST /api/v1/downloads/{id}/cancel`
    case cancel
    /// `POST /api/v1/downloads/{id}/retry`。后端只收 failed 的任务。
    case retry
    /// 把原任务的 `input` 当作**新任务**重新提交（`POST /api/v1/downloads`）。
    case restart
    /// `DELETE /api/v1/downloads/{id}`。后端只收终态任务。
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cancel: "停止"
        case .retry, .restart: "重新开始"
        case .delete: "删除"
        }
    }

    var symbolName: String {
        switch self {
        case .cancel: "stop.circle"
        case .retry, .restart: "arrow.clockwise"
        case .delete: "trash"
        }
    }

    /// 动作进行中时给用户看的一句话。
    var inFlightTitle: String {
        switch self {
        case .cancel: "正在停止…"
        case .retry, .restart: "正在重新开始…"
        case .delete: "正在删除…"
        }
    }

    /// 只有删除是破坏性且不可撤销的：它同时决定按钮的 `.destructive` 角色
    /// 和「进不进侧滑手势」。两者是同一件事，所以只有一个开关。
    var isDestructive: Bool { self == .delete }
}

// MARK: - 状态 → 可用动作（唯一推导处）

extension JobStatus {
    /// **状态到可用动作的唯一推导处。** 详情页的 ⋯ 菜单和总览列表的侧滑手势都读这里，
    /// 谁都不许自己再判一遍 —— 两处各判一次，迟早会在某个状态上分叉。
    ///
    /// 这张表就是后端规则的镜像，每一条都在本机起的后端上验过：
    ///
    /// | 状态 | cancel | delete | retry |
    /// | --- | --- | --- | --- |
    /// | queued / running | 200 | 409 `job is not in a terminal status` | 409 |
    /// | completed | 200（什么也没做） | 200 | 409 |
    /// | failed | 200（什么也没做） | 200 | **202** |
    /// | cancelled | 200（什么也没做） | 200 | **409 `only failed jobs can be retried`** |
    ///
    /// 两个不显然的地方：
    ///
    /// - **cancel 对终态任务是 200 而不是 409**（backend `manager.go:547-550` 直接
    ///   返回 nil，任务状态一点没变，响应体那句 `"cancelled"` 是在撒谎）。所以终态
    ///   不给「停止」不是为了躲 409，是因为按了什么也不会发生。
    /// - **cancelled 的任务不能 retry。** `manager.go:455` 是
    ///   `if job.Status != domain.JobFailed { return ErrJobNotRetryable }`，
    ///   已取消的任务打 `/retry` 一定是 409。用户仍然要「重新开始」，所以那一格给的是
    ///   `.restart`：拿原任务的 `input` 重新提交一个**新任务**（新 id，重新计配额）。
    ///   这是诚实的做法 —— 另一条路是干脆不给按钮。
    ///
    /// 顺序即菜单顺序：破坏性的放最后，跟 iOS 菜单的惯例一致。
    var availableActions: [JobAction] {
        switch self {
        case .queued, .running: [.cancel]
        case .completed: [.delete]
        case .failed: [.retry, .delete]
        case .cancelled: [.restart, .delete]
        }
    }

    /// 侧滑手势用的顺序。`swipeActions(edge: .trailing)` 里**先声明的排在最外侧**，
    /// 跟菜单顺序正好相反。反转而不是另写一张表 —— 可用性只有一个来源。
    ///
    /// **删除不在这里。** 它不可撤销，只从详情页的 ⋯ 菜单走：划一下就露出来的入口
    /// 离误触太近，而列表这一层连「删的是哪一条」都只有一行字。
    var trailingSwipeActions: [JobAction] {
        availableActions.filter { !$0.isDestructive }.reversed()
    }
}

// MARK: - 结果

enum JobActionOutcome: Equatable, Sendable {
    /// 已受理停止请求。任务真正变成 cancelled 是异步的，由事件流通知。
    case cancelling
    /// 同一个任务已重新入队（id 不变）。
    case requeued
    /// 已作为**新任务**重新提交。`newJobID` 为空表示后端接受了但没回任务对象。
    case restarted(newJobID: String?)
    /// 已删除。HTTP 200 就是「这条真的没了」，可以直接退出详情页。
    case deleted(jobID: String)
}

// MARK: - 错误措辞

/// 任务管理动作失败时给用户看的错误。
///
/// 为什么不直接用 `DownloadsAPIError.server`：`/api/v1/*` 的错误体是后端原本的
/// `{"error": "..."}`，而 `GatewayErrorBody.resolvedMessage` 读的是
/// `detail/message/title` —— 这三个字段在这个形状里一个都没有，于是
/// `errorDescription` 每次都退化成「服务器错误 (409)」。就算把 `error` 直接当消息
/// 显示也不行，那里装的可能是 `sql: no rows in result set`（后端 `GET` 404 的原文）。
/// 所以这里按「动作 + 状态码」自己给一句中文。
enum JobActionError: LocalizedError, Equatable {
    /// 404（以及 cancel 的那个 500，见下）：任务已经不在了。
    case jobGone(JobAction)
    /// 409：状态不对。
    case wrongState(JobAction)
    /// 429：门户的硬性日配额拒绝。
    case dailyQuotaExhausted
    /// 503：并发上限（自己的并发额度，或整个部署的队列满了）。
    case concurrencyLimited
    /// 提交被逐条拒绝（重新开始走的是提交路径，拒绝理由在 results[].error 里）。
    case submitRejected(String)

    var errorDescription: String? {
        switch self {
        case let .jobGone(action):
            switch action {
            case .delete: "这个任务已经不在了，不用再删一次"
            default: "这个任务已经不在了，可能刚刚被删除"
            }
        case let .wrongState(action):
            switch action {
            case .cancel: "任务状态刚刚变了，现在不能停止"
            case .delete: "任务还在进行中，先「停止」再删除"
            case .retry, .restart: "任务状态刚刚变了，只有失败的任务能重新开始"
            }
        case .dailyQuotaExhausted:
            "今天的下载额度已经用完了，额度在 UTC 00:00 重置"
        case .concurrencyLimited:
            "同时进行的下载已经排满了，等前面的任务结束再试"
        case let .submitRejected(reason):
            reason
        }
    }

    /// 把一个网络错误翻成上面那些措辞。翻不动的（网络不通、需要重新登录、
    /// 账号待批准）原样返回 —— 那些错误本来就已经有人话了。
    static func mapping(_ error: Error, action: JobAction) -> Error {
        guard case let .server(status, code, _)? = error as? DownloadsAPIError else {
            return error
        }
        switch status {
        case 404:
            return JobActionError.jobGone(action)
        case 409:
            return JobActionError.wrongState(action)
        case 429:
            return JobActionError.dailyQuotaExhausted
        case 503:
            return JobActionError.concurrencyLimited
        case 500 where action == .cancel && code == "job not found":
            // 后端 `cancelDownload`（server.go:608-614）把**所有**错误都写成 500，
            // 包括「任务不存在」——delete 和 retry 那两个 handler 是好好映射成 404 的。
            // 这一条是照着这个已知缺陷兜底，不是猜的：错误串就是 `db.ErrJobNotFound`
            // 的原文。后端哪天修成 404，上面那条 case 会接住，这里自然失效。
            return JobActionError.jobGone(action)
        default:
            return error
        }
    }
}

// MARK: - 网络调用

@MainActor
enum JobActionsAPI {
    static func perform(_ action: JobAction, on job: Job) async throws -> JobActionOutcome {
        do {
            switch action {
            case .cancel:
                try await DownloadsAPI.cancelDownload(id: job.id)
                return .cancelling
            case .retry:
                try await DownloadsAPI.retryDownload(id: job.id)
                return .requeued
            case .delete:
                try await DownloadsAPI.deleteDownload(id: job.id)
                return .deleted(jobID: job.id)
            case .restart:
                return try await restart(job)
            }
        } catch {
            throw JobActionError.mapping(error, action: action)
        }
    }

    /// 用原任务的 `input` 提交一个新任务。
    ///
    /// 跟首页那次提交走同一条路：不带 `force_overwrite`（让后端沿用运行时配置），
    /// 现取一次 media user token —— 后端**从不回显** `overrides.media_user_token`
    /// （`domain.go:183-188` 会剥掉，取消时还会从库里抹掉），私人歌单和电台没有新
    /// token 就下不动。
    private static func restart(_ job: Job) async throws -> JobActionOutcome {
        let mediaUserToken = try? await AppleMusicTokenService.currentUserToken()
        let response = try await DownloadsAPI.createDownload(
            input: job.input,
            mediaUserToken: mediaUserToken
        )
        if response.accepted > 0 {
            return .restarted(newJobID: response.firstAcceptedJobID)
        }
        // 同一个链接已经有在跑的任务了：后端的 canonical_key 唯一索引不让重复，
        // 这不是失败，跳到那个任务上就好。
        if let existing = response.firstExistingJobID {
            return .restarted(newJobID: existing)
        }
        throw JobActionError.submitRejected(response.firstError ?? "任务未被后端接受")
    }
}

// MARK: - 执行器

/// 动作失败时弹的那个 alert 的载荷。
struct JobActionFailure: Identifiable {
    let id = UUID()
    let action: JobAction
    let message: String
}

/// 两个入口共用的执行器：记住哪条任务上有动作在飞、失败了弹哪句话。
///
/// **成功之后不去改本地状态**（删除除外）。取消和重新开始的结果都由事件流送回来
/// （`download_upserted` / `job_cancelled` / `job_retried`），本地再抢着改一遍只会
/// 和事件打架。为了不让用户盯着一行没反应的列表，`inFlight` 会把那一行的状态文案
/// 换成「正在停止…」，等事件到了自然被真实状态顶掉。
///
/// 删除是唯一的例外：HTTP 200 已经证明这条没了，不是预测。
@MainActor
@Observable
final class JobActionRunner {
    private(set) var inFlight: [String: JobAction] = [:]
    var failure: JobActionFailure?

    func action(forJobID jobID: String) -> JobAction? { inFlight[jobID] }

    /// 用户点了某个动作，直接执行 —— 删除也不再多问一句。
    @discardableResult
    func run(_ action: JobAction, on job: Job) async -> JobActionOutcome? {
        // 同一条任务上已经有动作在飞就不重复发。侧滑手势很容易连点两下。
        guard inFlight[job.id] == nil else { return nil }
        inFlight[job.id] = action
        defer { inFlight[job.id] = nil }

        do {
            return try await JobActionsAPI.perform(action, on: job)
        } catch {
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else {
                return nil
            }
            failure = JobActionFailure(
                action: action,
                message: error.localizedDescription
            )
            return nil
        }
    }
}

// MARK: - 复用的 UI 片段

extension View {
    /// 动作失败的 alert。两个入口挂同一套，措辞才不会分叉。
    func jobActionFailureAlert(runner: JobActionRunner) -> some View {
        alert(item: Bindable(runner).failure) { failure in
            Alert(
                title: Text("\(failure.action.title)失败"),
                message: Text(failure.message),
                dismissButton: .default(Text("好"))
            )
        }
    }
}
