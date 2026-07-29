import UIKit
import UniformTypeIdentifiers

/// 分享面板只干一件事：把链接提交给后端，然后给两个出口——去主 App 看，或者关掉。
///
/// 这里刻意不显示任务详情（封面 / 音轨数 / 进度）。分享面板是个一闪而过的浮层，
/// 轮询进度既要一直占着扩展进程，看到的也不如主 App 和实时活动全。
final class ShareViewController: UIViewController {
    /// 主 App 的 URL scheme，见 `amdl-ios/Info.plist` 的 CFBundleURLTypes 和
    /// `ContentView.handleOpenURL`：带 job id 直接落到任务详情，不带就停在下载页。
    private static let appURLScheme = "amdl"

    private let iconView = UIImageView()
    private let statusLabel = UILabel()
    private let messageLabel = UILabel()
    private let openAppButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    private nonisolated let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private var submissionTask: Task<Void, Never>?
    private var createdJobID: String?
    private var hasStarted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        submissionTask = Task { [weak self] in
            await self?.submitSharedURL()
        }
    }

    deinit {
        submissionTask?.cancel()
        session.invalidateAndCancel()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        // 比原来高一点：缺令牌那几句要占三四行，300 装不下就会把按钮挤出去。
        preferredContentSize = CGSize(width: 340, height: 360)

        iconView.image = UIImage(systemName: "arrow.down.circle.fill")
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48)
        iconView.tintColor = .systemBlue
        iconView.contentMode = .center

        statusLabel.text = "正在创建下载任务"
        statusLabel.font = .preferredFont(forTextStyle: .title3)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        messageLabel.text = "正在读取分享的链接"
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        // 不限行数：缺令牌时这里要说清楚"为什么下不了、去哪儿修"，截断了就白说了。
        messageLabel.numberOfLines = 0

        var openConfiguration = UIButton.Configuration.borderedProminent()
        openConfiguration.title = "打开 App"
        openConfiguration.image = UIImage(systemName: "arrow.up.forward.app.fill")
        openConfiguration.imagePadding = 6
        openAppButton.configuration = openConfiguration
        openAppButton.addTarget(self, action: #selector(openApp), for: .touchUpInside)

        var closeConfiguration = UIButton.Configuration.gray()
        closeConfiguration.title = "关闭"
        closeButton.configuration = closeConfiguration
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            iconView,
            statusLabel,
            messageLabel,
            openAppButton,
            closeButton
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(18, after: iconView)
        stack.setCustomSpacing(6, after: statusLabel)
        stack.setCustomSpacing(24, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            iconView.heightAnchor.constraint(equalToConstant: 56),
            openAppButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    // MARK: - 两个出口

    @objc private func openApp() {
        // 提交还在路上时先等它跑完，否则扩展进程被换掉，任务就白建了。按钮上转个
        // 圈，用户知道点到了。
        openAppButton.configuration?.showsActivityIndicator = true
        Task { [weak self] in
            await self?.submissionTask?.value
            self?.openHostApp()
        }
    }

    @objc private func close() {
        submissionTask?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// 扩展里没有 `UIApplication`（`UIApplication.shared` 在扩展 target 里就是不可用
    /// API），但场景上的 `open(_:options:completionHandler:)` 是公开且没被废弃的，
    /// 扩展照样能调，这是唯一干净的跳转方式。
    ///
    /// `NSExtensionContext.open` 留作兜底：文档上它只承诺给 Today 扩展用，实测在
    /// 分享扩展里回调直接给 false，什么也不会发生。
    private func openHostApp() {
        guard let url = hostAppURL() else {
            close()
            return
        }

        guard let scene = view.window?.windowScene else {
            openViaExtensionContext(url)
            return
        }
        scene.open(url, options: nil) { opened in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if opened {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.openViaExtensionContext(url)
                }
            }
        }
    }

    private func openViaExtensionContext(_ url: URL) {
        extensionContext?.open(url) { _ in
            Task { @MainActor [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    /// 带上 job id 就直接落到那个任务的详情页，没有就停在下载列表。
    private func hostAppURL() -> URL? {
        var components = URLComponents()
        components.scheme = Self.appURLScheme
        components.host = "download"
        if let createdJobID, !createdJobID.isEmpty {
            components.path = "/\(createdJobID)"
        }
        return components.url
    }

    // MARK: - 提交

    private func submitSharedURL() async {
        do {
            let url = try await extractSharedURL()
            try Task.checkCancellation()
            messageLabel.text = url.absoluteString

            // 主 App 每次提交都现取一次 media user token；扩展问不到 MusicKit，
            // 读的是主 App 抄进钥匙串的那份副本。见 `MediaUserTokenStore`。
            let storedToken = MediaUserTokenStore.load()
            let need = AppleMusicShareLink.mediaUserTokenNeed(for: url)
            try Self.ensureTokenIsUsable(storedToken, need: need)

            let response = try await submit(url: url, mediaUserToken: storedToken?.value)
            try Task.checkCancellation()
            guard let jobID = response.jobID else {
                throw ShareSubmissionError.rejected(message: response.firstError)
            }
            createdJobID = jobID
            showCreatedState(missingArtworkToken: need == .artworkOnly && storedToken == nil)
        } catch is CancellationError {
            return
        } catch {
            showFailureState(message: Self.userFacingMessage(for: error))
        }
    }

    /// 提交之前就把「一定会失败」的那一种挡下来。
    ///
    /// 电台是唯一没有令牌就必然失败的类型：后端解析曲目要调
    /// `POST /v1/me/stations/next-tracks/{id}`，那个接口必须带用户令牌
    /// （`applemusic/catalog.go`：`station downloads require a media_user_token`），
    /// 而生产环境的 `catalog.media_user_token` fallback 是空的，兜不住。
    /// 让面板报一句「任务已创建」、用户几秒后在 App 里发现一条失败任务——这次的
    /// 报告就是这么来的，所以宁可当场说清楚。
    ///
    /// 私人歌单**不拦**：令牌在那里只用来补封面，没有也能把歌下完。
    private static func ensureTokenIsUsable(
        _ token: SharedMediaUserToken?,
        need: MediaUserTokenNeed
    ) throws {
        guard need == .required else { return }
        guard let token else { throw ShareSubmissionError.missingMediaUserToken }
        guard token.isFresh() else { throw ShareSubmissionError.staleMediaUserToken }
    }

    private func showCreatedState(missingArtworkToken: Bool) {
        iconView.image = UIImage(systemName: "checkmark.circle.fill")
        iconView.tintColor = .systemGreen
        statusLabel.text = "任务已创建"
        statusLabel.textColor = .label
        // 私人歌单没有令牌照样能下完，只是封面取不到。这不值得拦下提交，但也不该
        // 一声不吭——「封面不对」正是这次报告里的另一半。
        messageLabel.text = missingArtworkToken
            ? "进度在 App 和实时活动里看。缺 Apple Music 用户令牌，这个私人歌单的封面可能取不到——打开一次主 App 就能补上。"
            : "进度在 App 和实时活动里看"
    }

    private func showFailureState(message: String) {
        iconView.image = UIImage(systemName: "exclamationmark.circle.fill")
        iconView.tintColor = .systemRed
        statusLabel.text = "创建失败"
        statusLabel.textColor = .systemRed
        messageLabel.text = message
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return "无法连接下载后端，请检查后端地址和局域网连接"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func extractSharedURL() async throws -> URL {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers: [NSItemProvider] = items.flatMap { $0.attachments ?? [] }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try await provider.loadSharedURL(forTypeIdentifier: UTType.url.identifier) {
                return url
            }
        }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let url = try await provider.loadSharedURL(forTypeIdentifier: UTType.plainText.identifier) {
                return url
            }
        }

        throw ShareSubmissionError.missingURL
    }

    /// 主 App 换来的门户 access token，门户拿它做认证。
    ///
    /// 从 App Group 的 UserDefaults 搬到了 **Keychain**：以前存的是 Apple 的
    /// identity token，10 分钟就废，明文放着风险有限；现在存的是门户会话，
    /// refresh token 有 60 天寿命，不该躺在会进备份的明文 plist 里。
    ///
    /// `PortalCredentialStore` 在主 App target 里，扩展够不着（共享的只有
    /// `LiveActivityShared/`），所以这里是它的一份手抄，**四个常量必须和它逐字
    /// 一致**（service / account / access group）。access group 已经改成引用
    /// `BackendEndpoint.appGroupIdentifier`，剩下三个还是字面量。
    /// access group 用的是 App Group id——iOS 允许这么用，所以扩展读得到，而且
    /// 不需要新增任何 entitlement。
    ///
    /// 扩展**不做刷新**：它是个一闪而过的浮层，转 token 是主 App 的事。access
    /// token 过期时这里返回它、请求拿到 401，用户回主 App 打开一次就好了。
    private static func portalBearerToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lyjw131.amdl.portal",
            kSecAttrAccount as String: "session",
            kSecAttrAccessGroup as String: BackendEndpoint.appGroupIdentifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data),
              !stored.accessToken.isEmpty
        else { return nil }
        return stored.accessToken
    }

    /// `PortalCredentials` 的解码镜像。字段名必须一致。
    private struct StoredCredentials: Decodable {
        let accessToken: String
    }

    private static func authorized(_ request: inout URLRequest) {
        guard let token = portalBearerToken() else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// 门户地址从 `BackendEndpoint` 取，和主 App 是同一份代码、同一个 App Group
    /// 键。以前这里自己抄了一份默认地址和键名，主 App 改了地址而这边没跟上时，
    /// 分享面板会一直往旧域名提交。
    private func backendBaseURL() throws -> URL {
        let candidate = BackendEndpoint.baseURLString
        guard !candidate.isEmpty, let baseURL = URL(string: candidate) else {
            throw ShareSubmissionError.invalidBackendURL
        }
        return baseURL
    }

    private func submit(
        url sharedURL: URL,
        mediaUserToken: String?
    ) async throws -> ShareDownloadSubmitResponse {
        var request = URLRequest(url: try backendBaseURL().appending(path: "/api/v1/downloads"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.authorized(&request)
        request.httpBody = try JSONEncoder().encode(
            ShareDownloadCreateRequest(
                url: sharedURL.absoluteString,
                mediaUserToken: mediaUserToken
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ShareSubmissionError.invalidResponse
        }
        if response.statusCode == 202 || response.statusCode == 422,
           let result = try? JSONDecoder().decode(ShareDownloadSubmitResponse.self, from: data) {
            return result
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = try? JSONDecoder().decode(BackendError.self, from: data)
            // 「等待批准」是每个新用户第一次分享链接时会撞上的状态，泛泛的
            // 「后端请求失败 (403)」对他们毫无意义。扩展里没有登录入口，所以
            // 这句话得自己把用户指回主 App。
            switch body?.machineCode {
            case "pending_approval":
                throw ShareSubmissionError.notReady("账号正在等待管理员批准，批准后就能提交下载了。")
            case "suspended":
                throw ShareSubmissionError.notReady("这个账号已被停用，请联系管理员。")
            case "unauthenticated":
                throw ShareSubmissionError.notReady("登录已过期，请打开一次主 App 重新登录。")
            default:
                throw ShareSubmissionError.server(status: response.statusCode, message: body?.displayMessage)
            }
        }
        guard let result = try? JSONDecoder().decode(ShareDownloadSubmitResponse.self, from: data) else {
            throw ShareSubmissionError.invalidResponse
        }
        return result
    }
}

private struct ShareDownloadSubmitResponse: Decodable {
    let results: [ShareDownloadSubmitResult]

    var acceptedResult: ShareDownloadSubmitResult? {
        results.first { $0.status == "accepted" }
    }

    /// 已经有同样的任务在跑时后端不会再建一个，返回的是既有任务的 id——那也算成功，
    /// 「打开 App」照样该落到那个任务上。
    var jobID: String? {
        acceptedResult?.job?.id ?? results.compactMap(\.existingJobID).first
    }

    var firstError: String? {
        results.compactMap(\.error).first
    }
}

private struct ShareDownloadSubmitResult: Decodable {
    let status: String
    let job: ShareJob?
    let existingJobID: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, job, error
        case existingJobID = "existing_job_id"
    }
}

/// 只取 id：面板不再显示任务详情，标题、封面、音轨数都用不上了。
private struct ShareJob: Decodable {
    let id: String
}

private struct BackendError: Decodable {
    let error: String?
    let message: String?
    /// `/api/gw/*` 用的是 RFC 9457 problem+json，机器码在 `code` 里；`/api/v1/*`
    /// 保持后端原来的 `{"error":...}`。两边的**值是同一张表**，所以一个结构解两种。
    let code: String?
    let detail: String?

    var machineCode: String? { code ?? error }
    var displayMessage: String? { detail ?? message ?? error }
}

private enum ShareSubmissionError: LocalizedError {
    case missingURL
    case invalidBackendURL
    case invalidResponse
    case rejected(message: String?)
    /// 账号状态挡住了这次提交（等待批准 / 已停用 / 登录过期）。和 `.server` 分开，
    /// 是因为它们不是"出错了，重试一下"，而是"去做另一件事"。
    case notReady(String)
    /// 电台需要 media user token，而钥匙串里根本没有这份副本。
    case missingMediaUserToken
    /// 有副本，但已经旧到不该再信（主 App 每次进前台都会刷新它）。
    case staleMediaUserToken
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .missingURL:
            "没有找到可下载的链接"
        case .invalidBackendURL:
            "后端地址无效"
        case .invalidResponse:
            "后端返回了无效响应"
        case let .rejected(message):
            message ?? "后端没有接受这个下载任务"
        case .missingMediaUserToken:
            "电台下载需要 Apple Music 用户令牌，分享面板取不到。请先打开主 App，在「配置 → 调试 → Apple Music」里授权一次，再回来分享。"
        case .staleMediaUserToken:
            "Apple Music 用户令牌太旧，多半已失效，电台会下载失败。打开一次主 App 会自动刷新，然后再分享。"
        case let .notReady(message):
            message
        case let .server(status, message):
            message ?? "后端请求失败 (\(status))"
        }
    }
}

private extension NSItemProvider {
    func loadSharedURL(forTypeIdentifier typeIdentifier: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let url: URL?
                    if let itemURL = item as? URL {
                        url = itemURL
                    } else if let itemURL = item as? NSURL {
                        url = itemURL as URL
                    } else if let text = item as? String {
                        let range = NSRange(text.startIndex..., in: text)
                        let detector = try? NSDataDetector(
                            types: NSTextCheckingResult.CheckingType.link.rawValue
                        )
                        url = detector?.firstMatch(in: text, range: range)?.url
                    } else {
                        url = nil
                    }
                    continuation.resume(returning: url)
                }
            }
        }
    }
}
