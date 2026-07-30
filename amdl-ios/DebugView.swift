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
    /// 升级到「一个域名」时被丢弃的旧网关地址。见 `BackendEndpoint.GatewayMigration`。
    @State private var discardedGatewayBaseURL = BackendEndpoint.discardedGatewayBaseURL
    @State private var authorizationStatus = MusicAuthorization.currentStatus
    @State private var developerToken = ""
    @State private var musicUserToken = ""
    @State private var errorMessage: String?
    @State private var isRequestingAuthorization = false
    /// 抄给分享扩展的那份 media user token。扩展问不到 MusicKit，只能读这份副本，
    /// 所以「分享电台失败」第一个要看的就是它在不在、是什么时候写的。
    @State private var sharedMediaUserToken = MediaUserTokenStore.load()
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
                TextField(BackendEndpoint.defaultBaseURLString, text: $backendBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())

                LabeledContent("实时活动网关") {
                    Text(BackendEndpoint.apnsURLString(from: backendBaseURL))
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                if let discardedGatewayBaseURL {
                    // 只有从旧版本升上来、而且两个地址当初指向不同主机的用户会看到
                    // 这一段。实时活动的目标主机变了却不吭声，是这次要避免的事。
                    Label {
                        Text("旧版本里实时活动网关另填过 \(discardedGatewayBaseURL)。现在网关地址由上面这一个地址派生，那份设置已经不再使用。")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)

                    Button("知道了", action: dismissGatewayMigrationNotice)
                }
            } header: {
                Text("门户")
            } footer: {
                Text("整个 App 只有这一个地址：任务列表走 /api/v1，登录走 /oauth2，实时活动走 /apns，都由它派生。修改后请重新启动 App，以向新地址注册实时活动 token。")
            }

            Section {
                if appleAuth.isSignedIn {
                    LabeledContent("账号", value: appleAuth.email ?? "已登录")
                    LabeledContent("会话", value: appleTokenStatusText)
                    // 凭据是 Apple 的 identity token 本身，没有静默续期的办法，所以
                    // 过期是**常态**而不是异常，界面要直说一句，否则用户看到的只是
                    // "隔一阵就要重新登录"，像是坏了。
                    //
                    // 不要在这句话里写死时长。上面「会话」那行显示的是从 token 的
                    // `exp` 解出来的真实剩余时间；写死数字正是之前出过的错——文案说
                    // 十分钟，实际约一天。取舍见 GatewayCredential 的注释。
                    if !appleAuth.hasValidToken {
                        Label {
                            Text("登录已过期，重新登录一次即可。Apple 的登录凭据不能自动续期，到期后需要手动登录。")
                        } icon: {
                            Image(systemName: "clock.badge.exclamationmark")
                        }
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
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
                Text("「通过 Apple 登录」拿到的身份令牌只用来换一次门户会话，之后请求带的是门户签发的令牌：有效期 1 小时，过期自动续，续期凭证 60 天，所以正常情况下不需要再回到这里。令牌存在钥匙串里，只会发给门户域名，封面等第三方资源不会带上。")
            }

            Section("Apple Music") {
                LabeledContent("授权状态", value: authorizationStatusText)
                LabeledContent("分享扩展副本", value: sharedMediaUserTokenStatusText)

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
        .onAppear {
            appleAuth.refreshFromStore()
            sharedMediaUserToken = MediaUserTokenStore.load()
        }
    }

    /// 分享扩展那份副本的状态。它是**分享面板能不能下电台**的唯一依据，所以这里
    /// 说的是「有没有、多久前写的」，而不是令牌本身。
    private var sharedMediaUserTokenStatusText: String {
        guard let sharedMediaUserToken else { return "无（分享电台会被拦下）" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        let age = formatter.localizedString(for: sharedMediaUserToken.updatedAt, relativeTo: Date())
        return sharedMediaUserToken.isFresh() ? "已同步（\(age)）" : "过旧（\(age)）"
    }

    /// 门户 access token 的剩余时间。**过期不等于要重新登录**——刷新是自动的，
    /// 这里显示的是"下一次自动续期还有多久"，所以文案不能说"已过期，请重新登录"。
    private var appleTokenStatusText: String {
        guard appleAuth.hasValidToken else { return "无" }
        guard let expiresAt = appleAuth.expiresAt else { return "有效" }
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0 else { return "将自动续期" }
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

    private func dismissGatewayMigrationNotice() {
        BackendEndpoint.clearDiscardedGatewayBaseURL()
        discardedGatewayBaseURL = nil
    }

    private func requestAppleMusicAuthorization() async {
        isRequestingAuthorization = true
        errorMessage = nil

        defer {
            isRequestingAuthorization = false
        }

        let status = await MusicAuthorization.request()
        authorizationStatus = status

        // 授权被拒时 `freshTokens()` 不会跑，共享副本得在这里跟着清——它是分享
        // 扩展唯一的来源，留一份取不到对应授权的令牌只会让提交在后端才失败。
        defer { sharedMediaUserToken = MediaUserTokenStore.load() }

        guard status == .authorized else {
            developerToken = ""
            musicUserToken = ""
            MediaUserTokenStore.clear()
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
