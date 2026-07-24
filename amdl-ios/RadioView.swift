//
//  RadioView.swift
//  amdl-ios
//
//  Created by 梁杨峻玮 on 2026/7/4.
//

import SwiftUI
import MusicKit

struct RadioView: View {
    @State private var backendBaseURL = DownloadsAPI.baseURLString
    @AppStorage("liveActivityGatewayBaseURL") private var liveActivityGatewayBaseURL = LiveActivityGatewayAPI.defaultBaseURLString
    @State private var authorizationStatus = MusicAuthorization.currentStatus
    @State private var developerToken = ""
    @State private var musicUserToken = ""
    @State private var errorMessage: String?
    @State private var isRequestingAuthorization = false

    private var authorizationStatusText: String {
        switch authorizationStatus {
        case .notDetermined:
            "未请求"
        case .denied:
            "已拒绝"
        case .restricted:
            "受限制"
        case .authorized:
            "已授权"
        @unknown default:
            "未知"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.58.110:18080", text: $backendBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("后端")
                } footer: {
                    Text("下载页从这个地址读取任务列表。")
                }

                Section {
                    TextField("http://192.168.3.38:18081", text: $liveActivityGatewayBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("实时活动网关")
                } footer: {
                    Text("网关订阅后端任务事件流，并通过 APNs 把下载进度和状态推送到灵动岛。修改地址后请重新启动 App，以向新网关注册实时活动 token。")
                }

                Section("Apple Music") {
                    LabeledContent("授权状态", value: authorizationStatusText)

                    Button(action: authorizationButtonTapped) {
                        if isRequestingAuthorization {
                            ProgressView()
                        } else {
                            Label("授权 Apple Music", systemImage: "music.note")
                        }
                    }
                    .disabled(isRequestingAuthorization)

                    Button(action: openAppSettings) {
                        Label("打开系统设置", systemImage: "gear")
                    }

                    if !developerToken.isEmpty {
                        TokenValueView(title: "Developer Token", value: developerToken)
                    }

                    if !musicUserToken.isEmpty {
                        TokenValueView(title: "Music-User-Token", value: musicUserToken)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("调试") {
                    Button(action: clearImageCache) {
                        Label("清除图片缓存", systemImage: "photo.stack")
                    }
                }
            }
            .pageLargeTitle("配置")
            .onChange(of: backendBaseURL, initial: false, backendBaseURLChanged)
        }
    }

    private func authorizationButtonTapped() {
        Task {
            await requestAppleMusicAuthorization()
        }
    }

    private func clearImageCache() {
        Task {
            await ImageCache.shared.clearAll()
        }
        PrivatePlaylistArtworkStore.shared.clearCache()
    }

    private func backendBaseURLChanged(_ oldValue: String, _ newValue: String) {
        DownloadsAPI.baseURLString = newValue
    }

    private func requestAppleMusicAuthorization() async {
        isRequestingAuthorization = true
        errorMessage = nil

        defer {
            isRequestingAuthorization = false
        }

        let status = await MusicAuthorization.request()
        authorizationStatus = status

        guard status == .authorized else {
            developerToken = ""
            musicUserToken = ""
            errorMessage = "Apple Music 未授权，无法获取 Music-User-Token。"
            return
        }

        do {
            let tokens = try await AppleMusicTokenService.freshTokens()
            developerToken = tokens.developer
            musicUserToken = tokens.user
        } catch {
            developerToken = ""
            musicUserToken = ""
            errorMessage = "获取 token 失败：\(error.localizedDescription)"
        }
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        UIApplication.shared.open(settingsURL)
    }
}

private struct TokenValueView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .lineLimit(nil)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    RadioView()
}
