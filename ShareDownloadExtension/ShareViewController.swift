import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    /// 同主 App：不内置具体地址。用户没在主 App 里填过后端地址时，分享扩展会
    /// 走下面的 `guard` 分支提示去配置，而不是打到一个写死的地址上。
    private static let defaultBackendBaseURL = ""
    private static let backendBaseURLKey = "backendBaseURL"
    private static let appGroupIdentifier = "group.com.lyjw131.amdl.amdl-ios"

    private let artworkView = UIImageView()
    private let statusLabel = UILabel()
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()
    private let detailLabel = UILabel()
    private let actionButton = UIButton(type: .system)

    private nonisolated let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private var sharedURL: URL?
    private var submissionTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var displayedArtworkURL: URL?
    private var hasStarted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        startSubmission()
    }

    deinit {
        submissionTask?.cancel()
        artworkTask?.cancel()
        session.invalidateAndCancel()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 380, height: 480)

        artworkView.image = UIImage(systemName: "arrow.down.circle.fill")
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
        artworkView.tintColor = .systemBlue
        artworkView.backgroundColor = .secondarySystemBackground
        artworkView.contentMode = .center
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 16

        let artworkContainer = UIView()
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)

        statusLabel.text = "正在创建下载任务"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center

        titleLabel.text = "Apple Music 下载"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        metadataLabel.text = "正在读取任务信息"
        metadataLabel.font = .preferredFont(forTextStyle: .subheadline)
        metadataLabel.textColor = .secondaryLabel
        metadataLabel.textAlignment = .center

        progressView.progress = 0
        progressView.tintColor = .systemBlue

        progressLabel.text = "准备中"
        progressLabel.font = .preferredFont(forTextStyle: .footnote)
        progressLabel.textColor = .secondaryLabel
        progressLabel.textAlignment = .right
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)

        detailLabel.text = "正在读取 Apple Music 链接..."
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 3

        actionButton.configuration = .borderedProminent()
        actionButton.configuration?.title = "完成"
        actionButton.configuration?.image = UIImage(systemName: "checkmark")
        actionButton.configuration?.imagePadding = 6
        actionButton.addTarget(self, action: #selector(performPrimaryAction), for: .touchUpInside)
        actionButton.isHidden = true

        let progressRow = UIStackView(arrangedSubviews: [progressView, progressLabel])
        progressRow.axis = .horizontal
        progressRow.alignment = .center
        progressRow.spacing = 12

        let stack = UIStackView(arrangedSubviews: [
            artworkContainer,
            statusLabel,
            titleLabel,
            metadataLabel,
            progressRow,
            detailLabel,
            actionButton
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(18, after: artworkContainer)
        stack.setCustomSpacing(6, after: statusLabel)
        stack.setCustomSpacing(18, after: metadataLabel)
        stack.setCustomSpacing(20, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            artworkContainer.heightAnchor.constraint(equalToConstant: 104),
            artworkView.widthAnchor.constraint(equalToConstant: 104),
            artworkView.heightAnchor.constraint(equalToConstant: 104),
            artworkView.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
            artworkView.centerYAnchor.constraint(equalTo: artworkContainer.centerYAnchor),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    private func startSubmission() {
        submissionTask?.cancel()
        submissionTask = Task { [weak self] in
            await self?.loadSubmitAndPoll()
        }
    }

    @objc private func performPrimaryAction() {
        if actionButton.configuration?.title == "重试" {
            showSubmittingState()
            startSubmission()
            return
        }

        submissionTask?.cancel()
        artworkTask?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func loadSubmitAndPoll() async {
        do {
            let url: URL
            if let sharedURL {
                url = sharedURL
            } else {
                url = try await extractSharedURL()
            }
            try Task.checkCancellation()
            sharedURL = url
            detailLabel.text = url.absoluteString

            let response = try await submit(url: url)
            try Task.checkCancellation()
            guard let jobID = response.jobID else {
                throw ShareSubmissionError.rejected(message: response.firstError)
            }

            showCreatedState(job: response.job)
            await poll(jobID: jobID)
        } catch is CancellationError {
            return
        } catch {
            showFailureState(message: Self.userFacingMessage(for: error))
        }
    }

    private func poll(jobID: String) async {
        var refreshFailures = 0

        while !Task.isCancelled {
            do {
                let detail = try await fetchDetail(jobID: jobID)
                try Task.checkCancellation()
                refreshFailures = 0
                update(with: detail)

                if !detail.job.status.isActive {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                refreshFailures += 1
                detailLabel.text = refreshFailures == 1
                    ? "暂时无法刷新进度，正在重试..."
                    : "进度刷新失败，仍会继续重试"
            }

            try? await Task.sleep(for: .seconds(refreshFailures == 0 ? 1 : min(refreshFailures, 5)))
        }
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

    private func backendBaseURL() throws -> URL {
        let configuredBaseURL = UserDefaults(suiteName: Self.appGroupIdentifier)?
            .string(forKey: Self.backendBaseURLKey)
        let candidate = configuredBaseURL ?? Self.defaultBackendBaseURL
        guard !candidate.isEmpty, let baseURL = URL(string: candidate) else {
            throw ShareSubmissionError.invalidBackendURL
        }
        return baseURL
    }

    private func submit(url sharedURL: URL) async throws -> ShareDownloadSubmitResponse {
        var request = URLRequest(url: try backendBaseURL().appending(path: "/api/v1/downloads"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ShareDownloadRequest(urls: [sharedURL.absoluteString]))

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ShareSubmissionError.invalidResponse
        }
        if response.statusCode == 202 || response.statusCode == 422,
           let result = try? JSONDecoder().decode(ShareDownloadSubmitResponse.self, from: data) {
            return result
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(BackendError.self, from: data))?.displayMessage
            throw ShareSubmissionError.server(status: response.statusCode, message: message)
        }
        guard let result = try? JSONDecoder().decode(ShareDownloadSubmitResponse.self, from: data) else {
            throw ShareSubmissionError.invalidResponse
        }
        return result
    }

    private func fetchDetail(jobID: String) async throws -> ShareDownloadDetail {
        let encodedID = jobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobID
        let url = try backendBaseURL().appending(path: "/api/v1/downloads/\(encodedID)")
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw ShareSubmissionError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(BackendError.self, from: data))?.displayMessage
            throw ShareSubmissionError.server(status: response.statusCode, message: message)
        }
        guard let detail = try? JSONDecoder().decode(ShareDownloadDetail.self, from: data) else {
            throw ShareSubmissionError.invalidResponse
        }
        return detail
    }

    private func showSubmittingState() {
        artworkTask?.cancel()
        displayedArtworkURL = nil
        artworkView.image = UIImage(systemName: "arrow.down.circle.fill")
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
        artworkView.tintColor = .systemBlue
        artworkView.backgroundColor = .secondarySystemBackground
        artworkView.contentMode = .center
        statusLabel.text = "正在创建下载任务"
        statusLabel.textColor = .label
        titleLabel.text = "Apple Music 下载"
        metadataLabel.text = "正在读取任务信息"
        progressView.progress = 0
        progressView.tintColor = .systemBlue
        progressLabel.text = "准备中"
        detailLabel.text = sharedURL?.absoluteString ?? "正在读取 Apple Music 链接..."
        actionButton.configuration?.title = "完成"
        actionButton.configuration?.image = UIImage(systemName: "checkmark")
        actionButton.isHidden = true
    }

    private func showCreatedState(job: ShareJob?) {
        statusLabel.text = "任务已创建"
        statusLabel.textColor = .systemGreen
        actionButton.configuration?.title = "完成"
        actionButton.configuration?.image = UIImage(systemName: "checkmark")
        actionButton.isHidden = false

        if let job {
            update(job: job, items: [])
        } else {
            titleLabel.text = "正在解析任务信息"
            metadataLabel.text = "音轨数解析中"
            progressLabel.text = "排队中"
        }
    }

    private func update(with detail: ShareDownloadDetail) {
        update(job: detail.job, items: detail.items)
    }

    private func update(job: ShareJob, items: [ShareJobItem]) {
        statusLabel.text = job.status.displayName
        statusLabel.textColor = job.status.tintColor
        titleLabel.text = job.displayName

        let totalItems = max(job.totalItems, items.count)
        let itemCountText = totalItems > 0 ? "\(totalItems) 首音轨" : "音轨数解析中"
        metadataLabel.text = "\(job.type.displayName) · \(itemCountText)"

        let progress = ShareDownloadDetail.progress(job: job, items: items)
        progressView.setProgress(Float(progress), animated: true)
        progressView.tintColor = job.status.tintColor

        if totalItems > 0 {
            let finishedItems = items.isEmpty
                ? job.doneItems
                : items.filter(\.status.countsAsDone).count
            progressLabel.text = "\(min(finishedItems, totalItems))/\(totalItems) · \(Int((progress * 100).rounded()))%"
        } else {
            progressLabel.text = job.status.displayName
        }

        if let error = job.error, !error.isEmpty {
            detailLabel.text = error
        } else if let activeMessage = items.first(where: { $0.status.isActive })?.statusMessage,
                  !activeMessage.isEmpty {
            detailLabel.text = activeMessage
        } else {
            detailLabel.text = job.status.detailText
        }

        if let artworkURL = job.resolvedArtworkURL ?? items.compactMap(\.resolvedArtworkURL).first {
            loadArtwork(from: artworkURL)
        }
    }

    private func loadArtwork(from url: URL) {
        guard displayedArtworkURL != url else { return }
        displayedArtworkURL = url
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await session.data(from: url)
                try Task.checkCancellation()
                guard let image = UIImage(data: data), displayedArtworkURL == url else { return }
                artworkView.image = image
                artworkView.preferredSymbolConfiguration = nil
                artworkView.backgroundColor = .clear
                artworkView.contentMode = .scaleAspectFill
            } catch {
                if displayedArtworkURL == url {
                    displayedArtworkURL = nil
                }
            }
        }
    }

    private func showFailureState(message: String) {
        artworkTask?.cancel()
        displayedArtworkURL = nil
        artworkView.image = UIImage(systemName: "exclamationmark.circle.fill")
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
        artworkView.tintColor = .systemRed
        artworkView.backgroundColor = .secondarySystemBackground
        artworkView.contentMode = .center
        statusLabel.text = "创建失败"
        statusLabel.textColor = .systemRed
        titleLabel.text = "未能创建下载任务"
        metadataLabel.text = "请检查网络或后端配置"
        progressView.progress = 0
        progressView.tintColor = .systemRed
        progressLabel.text = "失败"
        detailLabel.text = message
        actionButton.configuration?.title = "重试"
        actionButton.configuration?.image = UIImage(systemName: "arrow.clockwise")
        actionButton.isHidden = false
    }
}

private struct ShareDownloadRequest: Encodable {
    let urls: [String]
}

private struct ShareDownloadSubmitResponse: Decodable {
    let results: [ShareDownloadSubmitResult]

    var acceptedResult: ShareDownloadSubmitResult? {
        results.first { $0.status == "accepted" }
    }

    var job: ShareJob? {
        acceptedResult?.job
    }

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

private struct ShareDownloadDetail: Decodable {
    let job: ShareJob
    let items: [ShareJobItem]

    static func progress(job: ShareJob, items: [ShareJobItem]) -> Double {
        guard !items.isEmpty else {
            guard job.totalItems > 0 else { return 0 }
            return min(max(Double(job.doneItems) / Double(job.totalItems), 0), 1)
        }
        return items.reduce(0) { $0 + $1.normalizedProgress } / Double(items.count)
    }
}

private struct ShareJob: Decodable {
    let id: String
    let input: String
    let type: ShareJobType
    let title: String?
    let artworkURL: String?
    let status: ShareJobStatus
    let totalItems: Int
    let doneItems: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, input, type, title, status, error
        case artworkURL = "artwork_url"
        case totalItems = "total_items"
        case doneItems = "done_items"
    }

    var displayName: String {
        guard let title, !title.isEmpty else { return input }
        return title
    }

    var resolvedArtworkURL: URL? {
        Self.resolveArtworkURL(artworkURL)
    }

    static func resolveArtworkURL(_ template: String?) -> URL? {
        guard let template, !template.isEmpty else { return nil }
        return URL(string: template
            .replacingOccurrences(of: "{w}", with: "312")
            .replacingOccurrences(of: "{h}", with: "312")
            .replacingOccurrences(of: "{f}", with: "jpg"))
    }
}

private struct ShareJobItem: Decodable {
    let artworkURL: String?
    let status: ShareJobItemStatus
    let progress: Double
    let statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case status, progress
        case artworkURL = "artwork_url"
        case statusMessage = "status_message"
    }

    var normalizedProgress: Double {
        min(max(progress, 0), 1)
    }

    var resolvedArtworkURL: URL? {
        ShareJob.resolveArtworkURL(artworkURL)
    }
}

private enum ShareJobType: String, Decodable {
    case song, album, playlist, artist, station

    var displayName: String {
        switch self {
        case .song: "歌曲"
        case .album: "专辑"
        case .playlist: "歌单"
        case .artist: "艺人"
        case .station: "电台"
        }
    }
}

private enum ShareJobStatus: String, Decodable {
    case queued, running, completed, failed, cancelled

    var isActive: Bool {
        self == .queued || self == .running
    }

    var displayName: String {
        switch self {
        case .queued: "排队中"
        case .running: "正在下载"
        case .completed: "下载完成"
        case .failed: "下载失败"
        case .cancelled: "已取消"
        }
    }

    var detailText: String {
        switch self {
        case .queued: "任务正在等待后端处理"
        case .running: "下载进度会自动刷新"
        case .completed: "所有音轨均已处理完毕"
        case .failed: "任务处理失败"
        case .cancelled: "任务已被取消"
        }
    }

    var tintColor: UIColor {
        switch self {
        case .queued, .running: .systemBlue
        case .completed: .systemGreen
        case .failed: .systemRed
        case .cancelled: .secondaryLabel
        }
    }
}

private enum ShareJobItemStatus: String, Decodable {
    case queued, resolving, downloading, decrypting, remuxing, tagging, saving
    case completed, failed, cancelled
    case skippedExisting = "skipped_existing"

    var isActive: Bool {
        switch self {
        case .queued, .resolving, .downloading, .decrypting, .remuxing, .tagging, .saving:
            true
        case .completed, .failed, .cancelled, .skippedExisting:
            false
        }
    }

    var countsAsDone: Bool {
        self == .completed || self == .skippedExisting
    }
}

private struct BackendError: Decodable {
    let error: String?
    let message: String?

    var displayMessage: String? { message ?? error }
}

private enum ShareSubmissionError: LocalizedError {
    case missingURL
    case invalidBackendURL
    case invalidResponse
    case rejected(message: String?)
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
