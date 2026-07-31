//
//  CreateDownloadIntent.swift
//  amdl-ios
//

import AppIntents
@preconcurrency import MusicKit

/// MusicKit 令牌的唯一入口（见 `AGENTS.md`）。
///
/// 除了向 SDK 要令牌，它还负责**把用户令牌抄一份进钥匙串**
/// （`MediaUserTokenStore`）。分享扩展问不到 MusicKit——它有自己的 bundle id、
/// Info.plist 里没有 `NSAppleMusicUsageDescription`、也没有能弹授权面板的宿主，
/// 那份副本是它唯一的来源。抄写放在这里而不是各个调用点，是因为这里本来就是
/// 令牌进入 App 的唯一那道门。
@MainActor
enum AppleMusicTokenService {
    /// 主 App 的本地偏好：是否在每次进入前台时把最新 media user token 写进后端。
    /// 开关不含敏感值，放 UserDefaults；令牌本身仍只进钥匙串和一次 HTTPS 请求。
    nonisolated static let syncToBackendOnActivationKey =
        "syncMediaUserTokenToBackendOnActivation"

    static var syncToBackendOnActivation: Bool {
        UserDefaults.standard.bool(forKey: syncToBackendOnActivationKey)
    }

    static func currentUserToken() async throws -> String? {
        guard MusicAuthorization.currentStatus == .authorized else {
            // 授权被撤销之后还留着旧副本，只会让分享扩展拿着一个必定被 Apple 拒掉
            // 的令牌去提交。没授权就等于没令牌，两边保持一致。
            MediaUserTokenStore.clear()
            return nil
        }
        let provider = MusicDataRequest.tokenProvider
        let developerToken = try await provider.developerToken(options: [])
        let userToken = try await provider.userToken(for: developerToken, options: [])
        MediaUserTokenStore.save(userToken)
        return userToken
    }

    static func freshTokens() async throws -> (developer: String, user: String) {
        let provider = MusicDataRequest.tokenProvider
        let developerToken = try await provider.developerToken(options: [])
        let userToken = try await provider.userToken(for: developerToken, options: [.ignoreCache])
        MediaUserTokenStore.save(userToken)
        return (developerToken, userToken)
    }

    /// 刷新给扩展用的那份副本，失败就算了。
    ///
    /// 主 App 每次进前台调一次。只在「从 App 里提交下载」时顺手写是不够的：
    /// 完全存在「装上 App、授权一次 Apple Music、之后只用分享面板」的用法，
    /// 那条路径下钥匙串里永远不会有令牌。
    static func refreshSharedToken() async {
        _ = try? await currentUserToken()
    }

    /// 忽略 MusicKit 缓存取得最新用户令牌，并用最小配置 patch 写入后端。
    ///
    /// `ConfigAPI` 的成功响应若明确说 `persisted == false`，令牌只进了后端内存，
    /// 不满足“同步到配置文件”，因此这里仍然报失败。旧后端不返回该字段时保持兼容。
    static func syncFreshUserTokenToBackend() async throws {
        guard MusicAuthorization.currentStatus == .authorized else {
            MediaUserTokenStore.clear()
            throw MediaUserTokenBackendSyncError.notAuthorized
        }
        let tokens = try await freshTokens()
        try Task.checkCancellation()
        let response = try await ConfigAPI.updateMediaUserToken(tokens.user)
        if response.persisted == false {
            throw MediaUserTokenBackendSyncError.notPersisted(response.reloadError)
        }
    }

    /// App 进入前台的统一入口。开关关闭时保持原来的“只刷新分享扩展副本”行为；
    /// 开启时 freshTokens() 同时刷新副本，所以不会向 MusicKit 重复取两次。
    static func refreshForAppActivation() async {
        guard syncToBackendOnActivation else {
            await refreshSharedToken()
            return
        }
        do {
            try await syncFreshUserTokenToBackend()
            print("[Apple Music] 已把最新 media user token 同步到后端配置")
        } catch {
            // 不打印 token；启动同步失败不能阻塞 App 的其他前台恢复工作。
            print("[Apple Music] 自动同步 media user token 失败：\(error.localizedDescription)")
        }
    }
}

private enum MediaUserTokenBackendSyncError: LocalizedError {
    case notAuthorized
    case notPersisted(String?)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Apple Music 未授权，无法获取 Music-User-Token。"
        case let .notPersisted(reloadError):
            if let reloadError, !reloadError.isEmpty {
                "后端只更新了内存，未写入配置文件：\(reloadError)"
            } else {
                "后端只更新了内存，未写入配置文件。"
            }
        }
    }
}

struct CreateDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "创建下载任务"
    static let description = IntentDescription("使用传入的 URL 创建下载任务。")
    static let openAppWhenRun = false

    @Parameter(title: "URL", description: "要下载的 Apple Music 链接")
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("创建下载任务") {
            \.$url
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let mediaUserToken = try await currentMediaUserToken()
        let response = try await DownloadsAPI.createDownload(
            input: url.absoluteString,
            mediaUserToken: mediaUserToken
        )

        if let jobID = await response.firstAcceptedJobID {
            return .result(dialog: "下载任务已创建（任务 ID：\(jobID)）")
        }

        if let jobID = await response.firstExistingJobID {
            return .result(dialog: "该链接已有下载任务（任务 ID：\(jobID)）")
        }

        let errorMessage = await response.firstError
        throw CreateDownloadIntentError.rejected(
            errorMessage ?? "任务未被后端接受"
        )
    }

    private func currentMediaUserToken() async throws -> String? {
        try await AppleMusicTokenService.currentUserToken()
    }
}

struct AMDLShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateDownloadIntent(),
            phrases: [
                "用 \(.applicationName) 创建下载任务",
                "在 \(.applicationName) 中创建下载任务"
            ],
            shortTitle: "创建下载任务",
            systemImageName: "arrow.down.circle.fill"
        )
    }
}

private enum CreateDownloadIntentError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message):
            message
        }
    }
}
