//
//  DebugView.swift
//  amdl-ios
//
//  Created by 梁杨峻玮 on 2026/7/4.
//

import SwiftUI
import MusicKit

/// 调试面板：集中放置后端 / 网关地址、Apple Music 授权与缓存清理等开发调试项。
/// 从「配置」页的「调试」入口进入，不再单独占用底部标签。
struct DebugView: View {
    @State private var backendBaseURL = DownloadsAPI.baseURLString
    @AppStorage("liveActivityGatewayBaseURL") private var liveActivityGatewayBaseURL = LiveActivityGatewayAPI.defaultBaseURLString
    @State private var authorizationStatus = MusicAuthorization.currentStatus
    @State private var developerToken = ""
    @State private var musicUserToken = ""
    @State private var errorMessage: String?
    @State private var isRequestingAuthorization = false
    @State private var appleAuth = AppleAuthStore.shared
    @State private var appleAuthError: String?

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
        Form {
            Section {
                TextField("http://localhost:18080", text: $backendBaseURL)
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
                TextField("http://localhost:18081", text: $liveActivityGatewayBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text("实时活动网关")
            } footer: {
                Text("网关订阅后端任务事件流，并通过 APNs 把下载进度和状态推送到灵动岛。修改地址后请重新启动 App，以向新网关注册实时活动 token。")
            }

            Section {
                if appleAuth.isSignedIn {
                    LabeledContent("账号", value: appleAuth.email ?? "已登录")
                    LabeledContent("令牌", value: appleTokenStatusText)
                    Button(role: .destructive, action: appleAuth.signOut) {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                Button(action: appleSignInTapped) {
                    if appleAuth.isSigningIn {
                        ProgressView()
                    } else {
                        Label(
                            appleAuth.isSignedIn ? "重新获取令牌" : "通过 Apple 登录",
                            systemImage: "apple.logo"
                        )
                    }
                }
                .disabled(appleAuth.isSigningIn)

                if let appleAuthError {
                    Text(appleAuthError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("网关认证")
            } footer: {
                Text("后端和实时活动网关都在 oauth2-proxy 后面，请求需要带上「通过 Apple 登录」签发的身份令牌。有效期约 24 小时，过期后无法静默续期，需要回到这里重新获取。令牌只会发给网关域名，封面等第三方资源不会带上。")
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

            Section("缓存") {
                Button(action: clearImageCache) {
                    Label("清除图片缓存", systemImage: "photo.stack")
                }
            }
        }
        .navigationTitle("调试")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: backendBaseURL, initial: false, backendBaseURLChanged)
        .onAppear { appleAuth.refreshFromStore() }
    }

    private var appleTokenStatusText: String {
        guard let expiresAt = appleAuth.expiresAt else { return "无" }
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0 else { return "已过期" }
        return "剩余 \(Int(remaining / 60)) 分 \(Int(remaining.truncatingRemainder(dividingBy: 60))) 秒"
    }

    private func appleSignInTapped() {
        appleAuthError = nil
        Task {
            do {
                try await appleAuth.signIn()
            } catch AppleAuthError.canceled {
                // 用户主动取消，不当成错误提示。
            } catch {
                appleAuthError = error.localizedDescription
            }
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
    NavigationStack {
        DebugView()
    }
}
