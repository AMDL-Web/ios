//
//  LogStreamView.swift
//  amdl-ios
//
//  「配置 → 日志 → 实时日志」页：订阅后端日志流，按级别筛选、搜索关键字，
//  点一条展开它的结构化属性。
//

import SwiftUI

struct LogStreamView: View {
    /// 后端日志级别与访问日志开关也放在本页的菜单里，不再单独占一层菜单。
    let configStore: ConfigStore

    @State private var store = LogStreamStore()

    var body: some View {
        content
            .navigationTitle("实时日志")
            .navigationBarTitleDisplayMode(.inline)
            // .always 让搜索栏常驻，不随滚动收起——日志页滚动频繁，收起后很难点回来。
            .searchable(
                text: $store.queryText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索消息与属性"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SaveStatusView(store: configStore)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    LogStreamMenu(store: store, configStore: configStore)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                LogStreamStatusBar(store: store)
            }
            // 搜索走服务端过滤，去抖后再重连，避免每敲一个字都断一次流。
            .task(id: store.queryText) {
                await store.debounceQuery()
            }
            // 任一筛选条件或暂停状态变化都会重建这个 task，从而重连。
            .task(id: store.streamKey) {
                await store.run()
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.entries) { entry in
                        LogRowView(
                            entry: entry,
                            isExpanded: store.isExpanded(entry),
                            toggle: { store.toggleExpanded(entry) }
                        )
                        Divider().padding(.leading, 16)
                    }
                }
            }
            // 日志是 tail 视图，新记录进来时保持贴住底部。
            .defaultScrollAnchor(.bottom)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch store.connection {
        case .connecting:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("正在连接日志流…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            ContentUnavailableView {
                Label("无法连接日志流", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(message)
            } actions: {
                Button {
                    store.retry()
                } label: {
                    Text("重试").frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
            }

        case .paused:
            ContentUnavailableView(
                "已暂停",
                systemImage: "pause.circle",
                description: Text("点右上角继续接收日志。")
            )

        default:
            ContentUnavailableView(
                "暂无日志",
                systemImage: "text.alignleft",
                description: Text(store.hasFilters
                    ? "当前筛选条件下没有记录，试试放宽级别或清空搜索。"
                    : "后端还没有产生日志，有新记录会自动出现。")
            )
        }
    }
}

// MARK: - 顶部状态条

/// 连接状态 + 当前条数，出问题时把原因摆在正上方而不是藏进空状态。
private struct LogStreamStatusBar: View {
    let store: LogStreamStore

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.connection.tint)
                .frame(width: 7, height: 7)

            Text(store.connection.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(store.connection.tint)

            if case let .failed(message) = store.connection {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if store.truncated {
                Label("有记录已被淘汰", systemImage: "scissors")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text("\(store.entries.count) 条")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .animation(.snappy, value: store.connection)
    }
}

// MARK: - 工具菜单

private struct LogStreamMenu: View {
    @Bindable var store: LogStreamStore
    @Bindable var configStore: ConfigStore

    var body: some View {
        HStack(spacing: 14) {
            Button {
                store.isLive.toggle()
            } label: {
                Image(systemName: store.isLive ? "pause.circle.fill" : "play.circle.fill")
            }
            .accessibilityLabel(store.isLive ? "暂停" : "继续")

            Menu {
                // 本地筛选：只改这一页显示什么，不碰后端。
                Section("筛选显示 · 不改后端") {
                    ForEach(LogLevel.selectable) { level in
                        Toggle(level.displayName, isOn: store.levelBinding(level))
                    }
                    Button("显示全部级别") { store.levels = [] }
                        .disabled(store.levels.isEmpty)
                    Button("清空当前列表", systemImage: "trash", role: .destructive) {
                        store.clear()
                    }
                }

                // 后端配置：放进子菜单，避免两组级别选项挤在同一层看起来像重复项。
                Section("后端配置 · 会保存") {
                    Menu("后端记录设置", systemImage: "externaldrive.badge.icloud") {
                        Picker("记录级别", selection: $configStore.form.loggingLevel) {
                            ForEach(ConfigOptions.loggingLevels, id: \.self) { level in
                                Text(level).tag(level)
                            }
                        }
                        Toggle("HTTP 访问日志", isOn: $configStore.form.accessLog)
                    }
                }
            } label: {
                Image(systemName: store.hasFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("筛选与设置")
        }
    }
}

// MARK: - 单行

private struct LogRowView: View {
    let entry: LogEntry
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.timeFormatter.string(from: entry.time))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    LogLevelBadge(level: entry.level)

                    Text(entry.message)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 62)
                }

                if isExpanded, !entry.attributes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(entry.attributes) { attribute in
                            HStack(alignment: .top, spacing: 6) {
                                Text(attribute.key)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 96, alignment: .leading)
                                Text(attribute.value)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption2.monospaced())
                    .padding(.leading, 62)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isExpanded)
    }

    /// 折叠时把最常用的两个属性摘出来，省得为看 component 就得展开。
    private var subtitle: String? {
        let parts = [entry.component, entry.jobID].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private struct LogLevelBadge: View {
    let level: LogLevel

    var body: some View {
        Text(level.badgeText)
            .font(.caption2.weight(.bold))
            .foregroundStyle(level.tint)
            .frame(width: 34)
            .padding(.vertical, 2)
            .background(level.tint.opacity(0.15), in: .rect(cornerRadius: 4, style: .continuous))
    }
}

extension LogLevel {
    var tint: Color {
        switch self {
        case .debug: .gray
        case .info: .blue
        case .warn: .orange
        case .error: .red
        case .unknown: .secondary
        }
    }
}

// MARK: - 状态

/// 持有日志缓冲、筛选条件与连接状态。筛选或暂停状态变化时 streamKey 随之变化，
/// 视图侧的 .task(id:) 会取消旧连接并重连。
@MainActor
@Observable
final class LogStreamStore {
    enum Connection: Equatable {
        case idle
        case connecting
        case live
        case paused
        case failed(String)

        var title: String {
            switch self {
            case .idle: "未连接"
            case .connecting: "连接中"
            case .live: "实时"
            case .paused: "已暂停"
            case .failed: "连接失败"
            }
        }

        var tint: Color {
            switch self {
            case .idle: .secondary
            case .connecting: .orange
            case .live: .green
            case .paused: .secondary
            case .failed: .red
            }
        }
    }

    /// 内存里最多保留的行数，超出后丢弃最旧的，避免长时间挂着把内存吃满。
    private static let capacity = 2000

    private(set) var entries: [LogEntry] = []
    private(set) var connection: Connection = .idle
    /// 后端提示游标之前的记录已被内存环淘汰。
    private(set) var truncated = false

    var isLive = true
    var levels: Set<LogLevel> = []
    /// 搜索框绑定的原始文本，去抖后写进 query 才参与筛选。
    var queryText = ""
    private(set) var query = ""

    private var expanded: Set<UInt64> = []
    private var lastSequence: UInt64?
    private var appliedFilter: LogFilter?
    /// 每次「重试」自增，用来让 .task(id:) 在筛选条件没变时也能重连。
    private var retryToken = 0

    var filter: LogFilter {
        LogFilter(levels: levels, query: query)
    }

    var hasFilters: Bool { !levels.isEmpty || !query.isEmpty }

    /// 视图用它作 .task(id:)：其中任一项变化都应重连。
    var streamKey: String {
        let levelKey = LogLevel.selectable
            .filter { levels.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
        return "\(isLive)|\(levelKey)|\(query)|\(retryToken)"
    }

    func levelBinding(_ level: LogLevel) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.levels.contains(level) ?? false },
            set: { [weak self] isOn in
                guard let self else { return }
                if isOn {
                    self.levels.insert(level)
                } else {
                    self.levels.remove(level)
                }
            }
        )
    }

    func isExpanded(_ entry: LogEntry) -> Bool { expanded.contains(entry.sequence) }

    func toggleExpanded(_ entry: LogEntry) {
        if expanded.contains(entry.sequence) {
            expanded.remove(entry.sequence)
        } else {
            expanded.insert(entry.sequence)
        }
    }

    func clear() {
        entries.removeAll()
        expanded.removeAll()
        truncated = false
        // 保留 lastSequence：清空只是清视图，重连仍应从上次位置续接。
    }

    func retry() {
        retryToken &+= 1
    }

    /// 搜索输入去抖：停止输入 400ms 后才把文本提交为筛选条件。
    func debounceQuery() async {
        let pending = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending != query else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        query = pending
    }

    /// 连接并消费日志流，断线后退避重连，直到 task 被取消。
    func run() async {
        // 筛选条件变了就重来：后端重放的是过滤后的记录，旧缓冲已经对不上。
        if appliedFilter != filter {
            appliedFilter = filter
            entries.removeAll()
            expanded.removeAll()
            lastSequence = nil
            truncated = false
        }

        guard isLive else {
            connection = .paused
            return
        }

        var backoff = Duration.milliseconds(500)
        while !Task.isCancelled {
            connection = entries.isEmpty ? .connecting : .live
            do {
                try await LogsAPI.stream(filter: filter, after: lastSequence) { [weak self] entry in
                    self?.append(entry)
                }
                // 正常返回意味着连接被对端关闭，退避后续接。
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                connection = .failed(Self.errorText(error))
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(10))
        }
    }

    private func append(_ entry: LogEntry) {
        connection = .live
        // 重连时后端可能重放已经显示过的记录，按 sequence 去重。
        if let last = lastSequence, entry.sequence <= last { return }
        lastSequence = entry.sequence
        entries.append(entry)
        if entries.count > Self.capacity {
            let overflow = entries.count - Self.capacity
            let dropped = entries.prefix(overflow)
            expanded.subtract(dropped.map(\.sequence))
            entries.removeFirst(overflow)
        }
    }

    private static func errorText(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#Preview {
    NavigationStack {
        LogStreamView(configStore: ConfigStore())
    }
}
