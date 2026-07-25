//
//  LogsAPI.swift
//  amdl-ios
//
//  后端进程日志（GET /api/v1/logs、GET /api/v1/logs/stream/ws）的模型与网络层。
//  日志页优先走 WebSocket 流：握手后后端先重放内存环里匹配的记录，再持续推送
//  新记录，断线用最后收到的 sequence 作 after 续接。
//

import Foundation

// MARK: - 模型

/// 日志级别。后端只会下发 debug/info/warn/error，未知值归到 unknown 以免解码失败。
enum LogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case debug
    case info
    case warn
    case error
    case unknown

    var id: String { rawValue }

    /// 用于筛选菜单，不含 unknown。
    static var selectable: [LogLevel] { [.debug, .info, .warn, .error] }

    var displayName: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warn: "WARN"
        case .error: "ERROR"
        case .unknown: "—"
        }
    }

    /// 行首徽标用的短标签，保证四个级别等宽。
    var badgeText: String {
        switch self {
        case .debug: "DBG"
        case .info: "INF"
        case .warn: "WRN"
        case .error: "ERR"
        case .unknown: "···"
        }
    }

    init(rawBackendValue: String) {
        self = LogLevel(rawValue: rawBackendValue.lowercased()) ?? .unknown
    }
}

/// 一条结构化日志。attributes 是后端的任意 JSON 对象，这里解码成展示用字符串，
/// 顺序按键名排序，保证同一条日志每次渲染顺序一致。
struct LogEntry: Identifiable, Sendable, Equatable {
    let sequence: UInt64
    let time: Date
    let level: LogLevel
    let message: String
    let source: String?
    let attributes: [Attribute]

    var id: UInt64 { sequence }

    struct Attribute: Identifiable, Sendable, Equatable {
        let key: String
        let value: String
        var id: String { key }
    }

    /// 约定俗成的几个属性单独提出来放在消息下方。
    var component: String? { attributes.first { $0.key == "component" }?.value }
    var jobID: String? { attributes.first { $0.key == "job_id" }?.value }
}

extension LogEntry: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sequence, time, level, message, source, attributes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        time = try Self.decodeTime(from: container)
        level = LogLevel(rawBackendValue: try container.decodeIfPresent(String.self, forKey: .level) ?? "")
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source)

        let raw = try container.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:]
        attributes = raw
            .map { Attribute(key: $0.key, value: $0.value.displayText) }
            .sorted { $0.key < $1.key }
    }

    /// Go 的 RFC3339Nano 在纳秒为 0 时不带小数位，所以两种格式都要试。
    private static func decodeTime(from container: KeyedDecodingContainer<CodingKeys>) throws -> Date {
        let raw = try container.decode(String.self, forKey: .time)
        if let parsed = fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw) {
            return parsed
        }
        throw DecodingError.dataCorruptedError(
            forKey: .time,
            in: container,
            debugDescription: "无法解析时间戳 \(raw)"
        )
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// attributes 的值类型不固定（数字/字符串/布尔/嵌套），只为展示，统一转成文本。
private enum JSONValue: Decodable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    var displayText: String {
        switch self {
        case let .string(value): value
        case let .int(value): String(value)
        case let .double(value): value == value.rounded() ? String(Int64(value)) : String(value)
        case let .bool(value): value ? "true" : "false"
        case .null: "null"
        case let .array(values): "[" + values.map(\.displayText).joined(separator: ", ") + "]"
        case let .object(values):
            "{" + values.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.displayText)" }
                .joined(separator: ", ") + "}"
        }
    }
}

/// GET /api/v1/logs 的返回体。
struct LogPage: Decodable, Sendable {
    let logs: [LogEntry]
    let nextCursor: UInt64
    let oldestSequence: UInt64
    /// after 早于内存环中最早的记录时为 true，表示中间有记录已被淘汰。
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case logs
        case nextCursor = "next_cursor"
        case oldestSequence = "oldest_sequence"
        case truncated
    }
}

// MARK: - 筛选条件

/// 服务端筛选条件，直接映射成查询参数。级别为空表示不限。
struct LogFilter: Equatable, Sendable {
    var levels: Set<LogLevel> = []
    var query = ""
    var component = ""
    var jobID = ""
    var limit = 300

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if !levels.isEmpty {
            // 后端按逗号分隔解析，顺序不影响语义，排序只为请求可复现。
            let value = LogLevel.selectable
                .filter { levels.contains($0) }
                .map(\.rawValue)
                .joined(separator: ",")
            items.append(URLQueryItem(name: "level", value: value))
        }
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if !component.isEmpty { items.append(URLQueryItem(name: "component", value: component)) }
        if !jobID.isEmpty { items.append(URLQueryItem(name: "job_id", value: jobID)) }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        return items
    }
}

// MARK: - 网络层

enum LogsAPI {
    /// 一次性查询。日志页在 WebSocket 不可用时用它兜底展示历史记录。
    static func list(filter: LogFilter, after: UInt64? = nil) async throws -> LogPage {
        var items = filter.queryItems
        if let after, after > 0 {
            items.append(URLQueryItem(name: "after", value: String(after)))
        }
        let url = try makeURL(path: "/api/v1/logs", queryItems: items)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadsAPIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw DownloadsAPIError.server(status: httpResponse.statusCode, message: errorMessage(from: data))
        }
        return try JSONDecoder().decode(LogPage.self, from: data)
    }

    /// 订阅日志流，直到调用方取消任务或连接断开。后端先重放 after 之后仍在内存里
    /// 的匹配记录，再持续推送新记录，每条是一条 JSON 文本消息。
    static func stream(
        filter: LogFilter,
        after: UInt64?,
        onEntry: (LogEntry) -> Void
    ) async throws {
        let url = try webSocketURL(filter: filter, after: after)
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()

        let decoder = JSONDecoder()
        try await withTaskCancellationHandler {
            while true {
                let message = try await socket.receive()
                try Task.checkCancellation()
                guard let data = messageData(message) else { continue }
                // 单条解码失败不该终止整条流，跳过继续读下一条。
                guard let entry = try? decoder.decode(LogEntry.self, from: data) else { continue }
                onEntry(entry)
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func messageData(_ message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case let .string(text): text.data(using: .utf8)
        case let .data(data): data
        @unknown default: nil
        }
    }

    /// 日志流的 WebSocket 端点；续接时带上最后收到的 sequence。
    static func webSocketURL(filter: LogFilter, after: UInt64?) throws -> URL {
        guard var components = URLComponents(string: DownloadsAPI.baseURLString) else {
            throw DownloadsAPIError.invalidBaseURL
        }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path = "/api/v1/logs/stream/ws"
        var items = filter.queryItems
        if let after, after > 0 {
            items.append(URLQueryItem(name: "after", value: String(after)))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw DownloadsAPIError.invalidBaseURL
        }
        return url
    }

    private static func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: DownloadsAPI.baseURLString) else {
            throw DownloadsAPIError.invalidBaseURL
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw DownloadsAPIError.invalidBaseURL
        }
        return url
    }

    private static func errorMessage(from data: Data) -> String? {
        struct Failure: Decodable {
            let error: String?
            let message: String?
        }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        return failure?.message ?? failure?.error
    }
}
