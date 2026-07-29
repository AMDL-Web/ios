//
//  DownloadDetailInfoView.swift
//  amdl-ios
//

import SwiftUI
import UIKit

/// 详情页「⋯ → 详细信息」里那张表的内容。规则是**只列页面上看不到的字段**：
/// 标题、艺人/策展人、流派、年份、曲库区域、音质徽标、进度和 x/y 计数都在概览里，
/// 专辑/歌单/艺人/电台页还有曲目行和底注（曲目数、合计时长与大小、发行日期、创建
/// 时间），所以这些一律不重复。剩下的补充项分三类：任务自身的元数据（类型、失败
/// 项、强制重下、时间戳、ID、原始链接）、从头到尾没展示过的 hook 执行结果，以及
/// 单曲页因为既没有曲目行也没有底注而无处可看的那部分曲目信息。
///
/// 判定「页面上有没有」靠的是 `job.type`：`DownloadDetailView` 按它在单曲概览和
/// 曲目列表两种版式之间切换。改那边的版式时，这里的取舍要跟着改。
enum DownloadDetailInfo {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
        var isMonospaced = false
        var isCopyable = false
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let rows: [Row]
    }

    static func sections(job: Job, items: [JobItem], hooks: [HookState]) -> [Section] {
        [
            trackSection(job: job, items: items),
            audioSection(job: job, items: items),
            taskSection(job: job),
            hookSection(hooks: hooks),
            identitySection(job: job, items: items)
        ].compactMap { $0 }
    }

    /// 单曲页只有一张概览卡：没有曲目行，也没有底注。专辑名、精确时长、成品大小和
    /// 完整发行日期（概览只给到年份）因此只在单曲任务里补。
    private static func trackSection(job: Job, items: [JobItem]) -> Section? {
        guard job.type == .song, let item = items.first else { return nil }

        var rows: [Row] = []
        if let album = nonempty(item.album) {
            rows.append(Row(id: "album", label: "专辑", value: album))
        }
        if let durationMs = item.durationMs, durationMs > 0 {
            rows.append(Row(id: "duration", label: "时长", value: durationText(milliseconds: durationMs)))
        }
        if let fileSize = item.fileSize, fileSize > 0 {
            rows.append(
                Row(id: "size", label: "文件大小", value: fileSize.formatted(.byteCount(style: .file)))
            )
        }
        if let releaseDate = ReleaseDatePresentation.longText(job.releaseDate) {
            rows.append(Row(id: "release", label: "发行日期", value: releaseDate))
        }
        return rows.isEmpty ? nil : Section(id: "track", title: "曲目", rows: rows)
    }

    /// 编码、位深度、采样率、码率平时挂在音质徽标背后：单曲和专辑靠概览那一枚，
    /// 歌单、电台、艺人靠每个曲目行自己那一枚。但概览的徽标只有无损和 Atmos 才会
    /// 生成，所以「单曲/专辑 + 没有徽标」是唯一看不到这几项的组合——只有这时才补，
    /// 其余情况点徽标就能看，不必重复一遍。
    private static func audioSection(job: Job, items: [JobItem]) -> Section? {
        guard job.type == .song || job.type == .album,
              AudioQualityPresentation.badges(for: items).isEmpty else {
            return nil
        }

        let rows = AudioQualityPresentation.fields(for: items).compactMap { field -> Row? in
            guard let value = field.value else { return nil }
            return Row(id: "audio.\(field.label)", label: field.label, value: value)
        }
        return rows.isEmpty ? nil : Section(id: "audio", title: "音频", rows: rows)
    }

    private static func taskSection(job: Job) -> Section {
        var rows = [Row(id: "type", label: "类型", value: typeText(job.type))]
        // 概览只报「已完成 x/y」，失败的那几项散在曲目行里；集合任务尤其看不出总数。
        if job.failedItems > 0 {
            rows.append(Row(id: "failed", label: "失败项", value: "\(job.failedItems) 项"))
        }
        rows.append(Row(id: "force", label: "强制重新下载", value: job.force ? "是" : "否"))
        // 集合任务的底注已经写了创建时间，单曲页没有底注。
        if job.type == .song {
            rows.append(Row(id: "created", label: "创建时间", value: timestampText(job.createdAt)))
        }
        rows.append(Row(id: "updated", label: "更新时间", value: timestampText(job.updatedAt)))
        return Section(id: "task", title: "任务", rows: rows)
    }

    /// hook 状态跟着详情快照一起下发，但详情页从头到尾没有展示过。
    private static func hookSection(hooks: [HookState]) -> Section? {
        guard !hooks.isEmpty else { return nil }

        let rows = hooks.map { hook in
            Row(
                id: "hook.\(hook.name)",
                label: hook.name,
                value: [hook.statusText, nonempty(hook.error)]
                    .compactMap { $0 }
                    .joined(separator: "：")
            )
        }
        return Section(id: "hooks", title: "Hook", rows: rows)
    }

    private static func identitySection(job: Job, items: [JobItem]) -> Section {
        var rows = [Row(id: "job", label: "任务 ID", value: job.id, isMonospaced: true, isCopyable: true)]
        if job.type == .song, let adamID = nonempty(items.first?.adamID) {
            rows.append(Row(id: "adam", label: "曲目 ID", value: adamID, isMonospaced: true, isCopyable: true))
        }
        // 标题解析出来之前，概览的大标题显示的就是原始链接（`Job.displayName`），
        // 这时再列一遍就是重复。
        if nonempty(job.title) != nil {
            rows.append(Row(id: "input", label: "原始链接", value: job.input, isCopyable: true))
        }
        return Section(id: "identity", title: "标识", rows: rows)
    }

    static func durationText(milliseconds: Int) -> String {
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        return Duration.seconds(seconds)
            .formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private static func typeText(_ type: JobType) -> String {
        switch type {
        case .song: "单曲"
        case .album: "专辑"
        case .playlist: "歌单"
        case .artist: "艺人"
        case .station: "电台"
        }
    }

    private static func timestampText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct DownloadDetailInfoView: View {
    let job: Job
    let items: [JobItem]
    let hooks: [HookState]

    @Environment(\.dismiss) private var dismiss
    @State private var copiedRowID: String?

    private var sections: [DownloadDetailInfo.Section] {
        DownloadDetailInfo.sections(job: job, items: items, hooks: hooks)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    SwiftUI.Section(section.title) {
                        ForEach(section.rows, content: row)
                    }
                }
            }
            .navigationTitle("详细信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            // 拷贝反馈自己退回去。用 task(id:) 而不是丢一个 Task 出去，切走或再点
            // 一行时上一轮会被取消，不会把新的反馈提前抹掉。
            .task(id: copiedRowID) {
                guard copiedRowID != nil else { return }
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation { copiedRowID = nil }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(_ row: DownloadDetailInfo.Row) -> some View {
        if row.isCopyable {
            Button {
                UIPasteboard.general.string = row.value
                withAnimation { copiedRowID = row.id }
            } label: {
                rowContent(row)
            }
            .buttonStyle(.plain)
            .accessibilityHint("轻点拷贝")
        } else {
            rowContent(row)
        }
    }

    private func rowContent(_ row: DownloadDetailInfo.Row) -> some View {
        let isCopied = copiedRowID == row.id
        return LabeledContent {
            HStack(spacing: 6) {
                Text(row.value)
                    .font(row.isMonospaced ? .callout.monospaced() : .callout)
                    .multilineTextAlignment(.trailing)
                if row.isCopyable {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(isCopied ? Color.green : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        } label: {
            Text(row.label)
        }
    }
}

#Preview("详细信息") {
    DownloadDetailInfoView(
        job: Job(
            id: "job_01HZX9",
            input: "https://music.apple.com/cn/album/preview/1234567890?i=1234567891",
            type: .song,
            storefront: "cn",
            title: "Preview Song",
            artworkURL: nil,
            force: true,
            status: .completed,
            totalItems: 1,
            doneItems: 1,
            failedItems: 0,
            error: nil,
            createdAt: .now,
            updatedAt: .now,
            releaseDate: "2024-03-15",
            genre: "J-Pop"
        ),
        items: [],
        hooks: [HookState(name: "notify", status: "succeeded")]
    )
}
