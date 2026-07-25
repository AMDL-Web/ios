//
//  CreateDownloadIntent.swift
//  amdl-ios
//

import AppIntents
@preconcurrency import MusicKit

@MainActor
enum AppleMusicTokenService {
    static func currentUserToken() async throws -> String? {
        guard MusicAuthorization.currentStatus == .authorized else { return nil }
        let provider = MusicDataRequest.tokenProvider
        let developerToken = try await provider.developerToken(options: [])
        return try await provider.userToken(for: developerToken, options: [])
    }

    static func freshTokens() async throws -> (developer: String, user: String) {
        let provider = MusicDataRequest.tokenProvider
        let developerToken = try await provider.developerToken(options: [])
        let userToken = try await provider.userToken(for: developerToken, options: [.ignoreCache])
        return (developerToken, userToken)
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
