//
//  RadioView.swift
//  amdl-ios
//
//  Created by 梁杨峻玮 on 2026/7/4.
//

import SwiftUI

/// 「配置」页：读取并编辑后端运行时配置（GET/PUT /api/v1/config）。
/// 拆成二级菜单，每类设置进入独立子页；改动即去抖后自动保存，无需保存按钮。
/// 底部的「调试」入口进入原来的开发调试项（后端/网关地址、Apple Music、缓存）。
struct RadioView: View {
    @State private var store = ConfigStore()

    var body: some View {
        NavigationStack {
            content
                .pageLargeTitle("配置") {
                    SaveStatusView(store: store)
                }
                .task {
                    if case .idle = store.phase {
                        await store.load()
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("正在读取后端配置…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            ContentUnavailableView {
                Label("无法读取配置", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(message)
            } actions: {
                Button {
                    Task { await store.load() }
                } label: {
                    Text("重试").frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)

                NavigationLink {
                    DebugView()
                } label: {
                    Text("打开调试").frame(minWidth: 96)
                }
                .buttonStyle(.bordered)
            }

        case .loaded:
            menu
        }
    }

    private var menu: some View {
        Form {
            if !store.persisted || store.reloadWarning != nil {
                Section {
                    if !store.persisted {
                        ConfigNoticeRow(
                            systemImage: "externaldrive.badge.exclamationmark",
                            tint: .orange,
                            title: "配置未写入磁盘",
                            message: "改动只在后端内存中生效，重启后端后会丢失。"
                        )
                    }
                    if let reloadWarning = store.reloadWarning {
                        ConfigNoticeRow(
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .red,
                            title: "配置文件加载告警",
                            message: reloadWarning
                        )
                    }
                }
            }

            Section("下载") {
                SettingsRow(
                    title: "下载行为",
                    systemImage: "slider.horizontal.3",
                    tint: .blue,
                    value: store.form.behaviorSummary
                ) {
                    BehaviorPage(store: store)
                }
                SettingsRow(
                    title: "下载音质",
                    systemImage: "waveform",
                    tint: .pink,
                    value: store.form.qualitySummary
                ) {
                    QualityPage(store: store)
                }
                SettingsRow(
                    title: "路径",
                    systemImage: "folder.fill",
                    tint: .indigo,
                    value: store.form.pathsSummary
                ) {
                    PathsPage(store: store)
                }
            }

            Section("元数据") {
                SettingsRow(
                    title: "歌词",
                    systemImage: "text.quote",
                    tint: .purple,
                    value: store.form.lyricsSummary
                ) {
                    LyricsPage(store: store)
                }
                SettingsRow(
                    title: "封面",
                    systemImage: "photo.fill",
                    tint: .orange,
                    value: store.form.coverSummary
                ) {
                    CoverPage(store: store)
                }
            }

            Section("后端") {
                SettingsRow(
                    title: "实时日志",
                    systemImage: "waveform.path.ecg",
                    tint: .mint,
                    value: store.form.loggingSummary
                ) {
                    LogStreamView(configStore: store)
                }
                SettingsRow(
                    title: "模拟模式",
                    systemImage: "testtube.2",
                    tint: .green,
                    value: store.form.simulateSummary
                ) {
                    SimulatePage(store: store)
                }
            }

            Section {
                SettingsRow(
                    title: "调试",
                    systemImage: "wrench.and.screwdriver.fill",
                    tint: .gray,
                    value: "后端地址 · Apple Music · 缓存"
                ) {
                    DebugView()
                }
            } footer: {
                Text("后端 / 网关地址、Apple Music 授权与缓存清理等开发调试项。")
            }
        }
    }
}

// MARK: - 菜单行

/// 二级入口行：彩色圆角图标 + 标题 + 当前取值摘要，摘要让菜单不点开也能看出配置。
private struct SettingsRow<Destination: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemImage: systemImage, tint: tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !value.isEmpty {
                        Text(value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// 仿系统「设置」的圆角方形图标底。
private struct SettingsIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(tint.gradient, in: .rect(cornerRadius: 7, style: .continuous))
    }
}

/// 顶部提醒行：配置未落盘、配置文件加载告警。
private struct ConfigNoticeRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(systemImage: systemImage, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 配置状态与自动保存

/// 持有配置表单、加载状态与保存状态。表单任意改动都会去抖后自动 PUT，
/// 从后端回填时用 isApplyingRemote 抑制误触发。
@MainActor
@Observable
final class ConfigStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    var phase: Phase = .idle
    var saveState: SaveState = .idle
    /// 配置是否已写入后端磁盘；false 表示只在内存生效。
    var persisted = true
    var reloadWarning: String?
    /// 后端是否开启了本地签名开发者 token 模式。关闭时签名模式相关选项不生效，
    /// 界面上直接不显示。
    var signedModeEnabled = false

    var form = ConfigForm() {
        didSet { scheduleSaveIfNeeded() }
    }

    @ObservationIgnored private var isApplyingRemote = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var savedResetTask: Task<Void, Never>?

    func load() async {
        phase = .loading
        do {
            let response = try await ConfigAPI.getConfig()
            applyRemote(ConfigForm(config: response.config))
            persisted = response.persisted ?? true
            reloadWarning = response.reloadError
            saveState = .idle
            phase = .loaded
            // 配置读到就先把页面显示出来，签名模式探测慢一点也不挡住主流程。
            signedModeEnabled = await ConfigAPI.signedModeEnabled()
        } catch {
            phase = .failed(Self.errorText(error))
        }
    }

    /// 回填后端数据时不触发保存。
    private func applyRemote(_ newForm: ConfigForm) {
        isApplyingRemote = true
        form = newForm
        isApplyingRemote = false
    }

    private func scheduleSaveIfNeeded() {
        guard !isApplyingRemote, phase == .loaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            await self.save()
        }
    }

    private func save() async {
        if let problem = form.validationError() {
            saveState = .failed(problem)
            return
        }
        saveState = .saving
        do {
            let response = try await ConfigAPI.updateConfig(form.toRuntimeConfig())
            persisted = response.persisted ?? true
            reloadWarning = response.reloadError
            markSaved()
        } catch {
            saveState = .failed(Self.errorText(error))
        }
    }

    private func markSaved() {
        saveState = .saved
        savedResetTask?.cancel()
        savedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            if self.saveState == .saved { self.saveState = .idle }
        }
    }

    static func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 保存状态指示

/// 右上角的自动保存状态胶囊：保存中、已保存、失败可点开详情。
struct SaveStatusView: View {
    let store: ConfigStore
    @State private var showError = false

    var body: some View {
        indicator
            .animation(.snappy, value: store.saveState)
    }

    @ViewBuilder
    private var indicator: some View {
        switch store.saveState {
        case .idle:
            EmptyView()
        case .saving:
            statusLabel(text: "保存中", tint: .secondary) {
                ProgressView().controlSize(.mini)
            }
        case .saved:
            statusLabel(text: "已保存", tint: .green) {
                Image(systemName: "checkmark.circle.fill")
            }
        case let .failed(message):
            Button {
                showError = true
            } label: {
                statusLabel(text: "保存失败", tint: .red) {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
            }
            .buttonStyle(.plain)
            .alert("保存失败", isPresented: $showError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message)
            }
        }
    }

    private func statusLabel(
        text: String,
        tint: Color,
        @ViewBuilder icon: () -> some View
    ) -> some View {
        HStack(spacing: 4) {
            icon()
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: .capsule)
    }
}

extension View {
    /// 子页复用的右上角保存状态。
    func configSaveStatusToolbar(_ store: ConfigStore) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SaveStatusView(store: store)
            }
        }
    }
}

// MARK: - 二级菜单子页

private struct BehaviorPage: View {
    @Bindable var store: ConfigStore
    var body: some View {
        Form {
            BehaviorSection(form: $store.form, signedModeEnabled: store.signedModeEnabled)
        }
            .navigationTitle("下载行为")
            .navigationBarTitleDisplayMode(.inline)
            .configSaveStatusToolbar(store)
    }
}

private struct QualityPage: View {
    @Bindable var store: ConfigStore
    var body: some View {
        Form { QualitySection(form: $store.form) }
            .navigationTitle("下载音质")
            .navigationBarTitleDisplayMode(.inline)
            .configSaveStatusToolbar(store)
            .animation(.snappy, value: store.form.codecAlternative)
            .animation(.snappy, value: store.form.usesALAC)
    }
}

private struct LyricsPage: View {
    @Bindable var store: ConfigStore
    var body: some View {
        Form { LyricsSection(form: $store.form) }
            .navigationTitle("歌词")
            .navigationBarTitleDisplayMode(.inline)
            .configSaveStatusToolbar(store)
    }
}

private struct CoverPage: View {
    @Bindable var store: ConfigStore
    var body: some View {
        Form { CoverSection(form: $store.form) }
            .navigationTitle("封面")
            .navigationBarTitleDisplayMode(.inline)
            .configSaveStatusToolbar(store)
    }
}

private struct PathsPage: View {
    @Bindable var store: ConfigStore
    var body: some View {
        Form { PathsSection(form: $store.form) }
            .navigationTitle("路径")
            .navigationBarTitleDisplayMode(.inline)
            .configSaveStatusToolbar(store)
    }
}

private struct SimulatePage: View {
    @Bindable var store: ConfigStore
    var body: some View {
        Form { SimulateSection(form: $store.form) }
            .navigationTitle("模拟模式")
            .navigationBarTitleDisplayMode(.inline)
            .configSaveStatusToolbar(store)
            .animation(.snappy, value: store.form.simulateEnabled)
    }
}

// MARK: - 表单模型

/// 配置页的可编辑视图模型。字段均为非可选，缺省值取后端 Default()；
/// 从后端读到的值覆盖缺省，保存时回写为完整 RuntimeConfig。
struct ConfigForm: Equatable {
    // catalog
    var albumTrackURLMode = "song"
    /// App 里不再提供编辑入口，但仍随读取的值原样回写，避免保存时把后端上
    /// 已配置的 token 清空。
    var mediaUserToken = ""
    var signedModeHLSSource = "wrapper"

    // download
    var qualityPriority: [CodecID] = [.alac]
    var codecAlternative = true
    var memoryMode = "low"
    var maxAttempts = 4
    var alacMaxSampleRate = 192000
    var alacMaxBitDepth = 24
    var checkIntegrity = true
    var forceOverwrite = false

    // download - cover
    var coverSize = "5000x5000"
    var coverFormat = "jpg"
    var embedCover = true
    var saveAlbumCover = false
    var saveArtistCover = false
    var savePlaylistCover = false

    // download - lyrics
    var embedLyrics = true
    var saveLyricsFile = false
    var lyricsFormat = "lrc"
    var lyricsType = "lyrics"
    var lyricsExtras: [LyricsExtra] = []

    // download - paths
    var downloadsDir = "data/downloads"
    var tempDir = "data/tmp"
    var songPathFormat = "songs/{ArtistName}/{AlbumName}/{TrackNumber:02d}. {SongName}"
    var albumPathFormat = "albums/{ArtistName}/{AlbumName}/{TrackNumber:02d}. {SongName}"
    var artistPathFormat = "artists/{ArtistName}/{AlbumName}/{TrackNumber:02d}. {SongName}"
    var playlistPathFormat = "playlists/{PlaylistName}/{SongNumber:02d}. {SongName}"
    var stationPathFormat = "stations/{StationName}/{SongNumber:02d}. {SongName}"

    // logging
    var loggingLevel = "info"
    var accessLog = false

    // simulate
    var simulateEnabled = false
    var simulateMinKbps = 512
    var simulateMaxKbps = 4096

    init() {}

    init(config: RuntimeConfig) {
        if let c = config.catalog {
            albumTrackURLMode = c.albumTrackURLMode ?? albumTrackURLMode
            mediaUserToken = c.mediaUserToken ?? mediaUserToken
            signedModeHLSSource = c.signedModeHLSSource ?? signedModeHLSSource
        }
        if let d = config.download {
            if let priority = d.qualityPriority, !priority.isEmpty { qualityPriority = priority }
            codecAlternative = d.codecAlternative ?? codecAlternative
            memoryMode = d.memoryMode ?? memoryMode
            maxAttempts = d.maxAttempts ?? maxAttempts
            alacMaxSampleRate = d.alacMaxSampleRate ?? alacMaxSampleRate
            alacMaxBitDepth = d.alacMaxBitDepth ?? alacMaxBitDepth
            checkIntegrity = d.checkIntegrity ?? checkIntegrity
            forceOverwrite = d.forceOverwrite ?? forceOverwrite
            coverSize = d.coverSize ?? coverSize
            coverFormat = d.coverFormat ?? coverFormat
            embedCover = d.embedCover ?? embedCover
            saveAlbumCover = d.saveAlbumCover ?? saveAlbumCover
            saveArtistCover = d.saveArtistCover ?? saveArtistCover
            savePlaylistCover = d.savePlaylistCover ?? savePlaylistCover
            embedLyrics = d.embedLyrics ?? embedLyrics
            saveLyricsFile = d.saveLyricsFile ?? saveLyricsFile
            lyricsFormat = d.lyricsFormat ?? lyricsFormat
            lyricsType = d.lyricsType ?? lyricsType
            lyricsExtras = d.lyricsExtras ?? lyricsExtras
            downloadsDir = d.downloadsDir ?? downloadsDir
            tempDir = d.tempDir ?? tempDir
            songPathFormat = d.songPathFormat ?? songPathFormat
            albumPathFormat = d.albumPathFormat ?? albumPathFormat
            artistPathFormat = d.artistPathFormat ?? artistPathFormat
            playlistPathFormat = d.playlistPathFormat ?? playlistPathFormat
            stationPathFormat = d.stationPathFormat ?? stationPathFormat
        }
        if let l = config.logging {
            loggingLevel = l.level ?? loggingLevel
            accessLog = l.accessLog ?? accessLog
        }
        if let s = config.simulate {
            simulateEnabled = s.enabled ?? simulateEnabled
            simulateMinKbps = s.minSpeedKbps ?? simulateMinKbps
            simulateMaxKbps = s.maxSpeedKbps ?? simulateMaxKbps
        }
    }

    var usesALAC: Bool { qualityPriority.contains(.alac) }

    func validationError() -> String? {
        if qualityPriority.isEmpty {
            return "请至少选择一种下载编码。"
        }
        if maxAttempts < 1 || maxAttempts > 10 {
            return "最大尝试次数需在 1–10 之间。"
        }
        if simulateEnabled {
            if simulateMinKbps < 1 {
                return "模拟最小速度需 ≥ 1 KB/s。"
            }
            if simulateMaxKbps < simulateMinKbps {
                return "模拟最大速度需 ≥ 最小速度。"
            }
        }
        return nil
    }

    func toRuntimeConfig() -> RuntimeConfig {
        RuntimeConfig(
            catalog: CatalogConfig(
                albumTrackURLMode: albumTrackURLMode,
                mediaUserToken: mediaUserToken,
                signedModeHLSSource: signedModeHLSSource
            ),
            download: DownloadConfig(
                qualityPriority: qualityPriority,
                codecAlternative: codecAlternative,
                memoryMode: memoryMode,
                maxAttempts: maxAttempts,
                downloadsDir: downloadsDir,
                songPathFormat: songPathFormat,
                albumPathFormat: albumPathFormat,
                artistPathFormat: artistPathFormat,
                playlistPathFormat: playlistPathFormat,
                stationPathFormat: stationPathFormat,
                tempDir: tempDir,
                coverSize: coverSize,
                coverFormat: coverFormat,
                embedCover: embedCover,
                saveAlbumCover: saveAlbumCover,
                saveArtistCover: saveArtistCover,
                savePlaylistCover: savePlaylistCover,
                embedLyrics: embedLyrics,
                saveLyricsFile: saveLyricsFile,
                lyricsFormat: lyricsFormat,
                lyricsType: lyricsType,
                lyricsExtras: lyricsExtras,
                alacMaxSampleRate: alacMaxSampleRate,
                alacMaxBitDepth: alacMaxBitDepth,
                checkIntegrity: checkIntegrity,
                forceOverwrite: forceOverwrite
            ),
            logging: LoggingConfig(level: loggingLevel, accessLog: accessLog),
            simulate: SimulateConfig(
                enabled: simulateEnabled,
                minSpeedKbps: simulateMinKbps,
                maxSpeedKbps: simulateMaxKbps
            )
        )
    }
}

// MARK: - 菜单摘要

/// 主菜单每行副标题展示的当前取值，随表单实时更新。
private extension ConfigForm {
    var behaviorSummary: String {
        [
            ConfigOptions.label(memoryMode, in: ConfigOptions.memoryModes),
            "重试 \(maxAttempts) 次"
        ].joined(separator: " · ")
    }

    var qualitySummary: String {
        guard let first = qualityPriority.first else { return "未选择编码" }
        var parts = [first.displayName]
        if codecAlternative, qualityPriority.count > 1 {
            parts.append("+\(qualityPriority.count - 1) 个备用")
        }
        if usesALAC {
            parts.append("\(ConfigOptions.sampleRateLabel(alacMaxSampleRate)) / \(alacMaxBitDepth) bit")
        }
        return parts.joined(separator: " · ")
    }

    var pathsSummary: String { downloadsDir }

    var lyricsSummary: String {
        var parts: [String] = []
        if embedLyrics { parts.append("嵌入") }
        if saveLyricsFile { parts.append("存为 \(lyricsFormat.uppercased())") }
        guard !parts.isEmpty else { return "已关闭" }
        if !lyricsExtras.isEmpty {
            parts.append(lyricsExtras.map(\.displayName).joined(separator: "、"))
        }
        return parts.joined(separator: " · ")
    }

    var coverSummary: String {
        var parts = [
            coverSize.replacingOccurrences(of: "x", with: "×"),
            coverFormat.uppercased()
        ]
        if !embedCover { parts.append("不嵌入") }
        return parts.joined(separator: " · ")
    }

    var loggingSummary: String {
        accessLog ? "\(loggingLevel) · 含访问日志" : loggingLevel
    }

    var simulateSummary: String {
        simulateEnabled ? "已开启 · \(simulateMinKbps)–\(simulateMaxKbps) KB/s" : "已关闭"
    }
}

// MARK: - 选项常量

enum ConfigOptions {
    static let albumTrackURLModes: [(value: String, label: String)] = [
        ("song", "单曲（?i= 只下该曲）"),
        ("album", "整张（?i= 下整张专辑）")
    ]
    static let memoryModes: [(value: String, label: String)] = [
        ("low", "低内存"),
        ("high", "高内存")
    ]
    static let signedModeHLSSources: [(value: String, label: String)] = [
        ("wrapper", "Wrapper"),
        ("web_token", "Web Token")
    ]
    static let coverSizes = ["5000x5000", "3000x3000", "1400x1400", "600x600"]
    static let coverFormats = ["jpg", "jpeg", "png"]
    static let lyricsFormats = ["lrc", "ttml"]
    static let lyricsTypes: [(value: String, label: String)] = [
        ("lyrics", "逐行"),
        ("syllable-lyrics", "逐字")
    ]
    static let loggingLevels = ["debug", "info", "warn", "error"]
    static let alacSampleRates = [44100, 48000, 96000, 192000]
    static let alacBitDepths = [16, 24]

    /// 把存储值翻译成展示文案，找不到时回落到原值。
    static func label(_ value: String, in options: [(value: String, label: String)]) -> String {
        options.first { $0.value == value }?.label ?? value
    }

    static func sampleRateLabel(_ hz: Int) -> String {
        let khz = Double(hz) / 1000
        let text = khz.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", khz)
            : String(format: "%.1f", khz)
        return "\(text) kHz"
    }
}

// MARK: - 各配置分区

private struct BehaviorSection: View {
    @Binding var form: ConfigForm
    /// 后端未开启本地签名模式时，HLS 源设置不生效，整段不显示。
    let signedModeEnabled: Bool

    var body: some View {
        Section {
            Picker("专辑链接下载模式", selection: $form.albumTrackURLMode) {
                ForEach(ConfigOptions.albumTrackURLModes, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }

            Picker("内存模式", selection: $form.memoryMode) {
                ForEach(ConfigOptions.memoryModes, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        } footer: {
            Text("专辑链接下载模式决定带 ?i= 的专辑链接下载单曲还是整张。")
        }

        if signedModeEnabled {
            Section {
                Picker("签名模式 HLS 源", selection: $form.signedModeHLSSource) {
                    ForEach(ConfigOptions.signedModeHLSSources, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
            } footer: {
                Text("后端正以本地签名的开发者 token 运行，这里决定 Enhanced HLS 主播放列表从哪取。")
            }
        }

        Section {
            Stepper(value: $form.maxAttempts, in: 1...10) {
                HStack {
                    Text("最大尝试次数")
                    Spacer()
                    Text("\(form.maxAttempts)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("校验输出完整性", isOn: $form.checkIntegrity)
            Toggle("覆盖已存在文件", isOn: $form.forceOverwrite)
        } header: {
            Text("重试与写入")
        } footer: {
            Text("覆盖已存在文件是新任务的默认值，可在提交时单独覆盖。")
        }
    }
}

private struct QualitySection: View {
    @Binding var form: ConfigForm

    private var available: [CodecID] {
        CodecID.allCases.filter { !form.qualityPriority.contains($0) }
    }

    var body: some View {
        Section {
            Toggle("备用编码", isOn: $form.codecAlternative)
                .onChange(of: form.codecAlternative) { _, enabled in
                    if !enabled, form.qualityPriority.count > 1 {
                        // 关闭备用编码时只保留首选编码，与前端一致。
                        form.qualityPriority = Array(form.qualityPriority.prefix(1))
                    }
                }

            if !form.codecAlternative {
                Picker("编码", selection: singleCodecBinding) {
                    ForEach(CodecID.allCases) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }
            }
        } footer: {
            Text("开启后可排定多个编码的回退顺序，某个编码失败就尝试下一个。")
        }

        // 编码优先级直接内嵌在本页：拖动排序、划动删除、菜单添加。
        if form.codecAlternative {
            Section {
                ForEach(Array(form.qualityPriority.enumerated()), id: \.element) { index, codec in
                    codecRow(rank: index + 1, name: codec.displayName, isFallback: false)
                }
                .onMove { indices, destination in
                    form.qualityPriority.move(fromOffsets: indices, toOffset: destination)
                }
                .onDelete { offsets in
                    guard form.qualityPriority.count - offsets.count >= 1 else { return }
                    form.qualityPriority.remove(atOffsets: offsets)
                }

                // 后端固定追加的兜底编码，不可编辑，列出来避免顺序看起来缺一环。
                codecRow(rank: form.qualityPriority.count + 1, name: "AAC-LC", isFallback: true)

                if !available.isEmpty {
                    Menu {
                        ForEach(available) { codec in
                            Button(codec.displayName) { form.qualityPriority.append(codec) }
                        }
                    } label: {
                        Label("添加编码", systemImage: "plus.circle.fill")
                    }
                }
            } header: {
                HStack {
                    Text("编码优先级")
                    Spacer()
                    EditButton()
                        .textCase(nil)
                        .font(.subheadline)
                }
            } footer: {
                Text("从上到下依次尝试。点右上角进入编辑可拖动排序或删除，至少保留一个。")
            }
        }

        if form.usesALAC {
            Section("ALAC 上限") {
                Picker("最高采样率", selection: $form.alacMaxSampleRate) {
                    ForEach(ConfigOptions.alacSampleRates, id: \.self) { rate in
                        Text(ConfigOptions.sampleRateLabel(rate)).tag(rate)
                    }
                }
                Picker("最高位深", selection: $form.alacMaxBitDepth) {
                    ForEach(ConfigOptions.alacBitDepths, id: \.self) { depth in
                        Text("\(depth) bit").tag(depth)
                    }
                }
            }
        }
    }

    /// 带序号徽标的编码行；兜底行灰显且不参与排序。
    private func codecRow(rank: Int, name: String, isFallback: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background((isFallback ? Color.gray : Color.accentColor).gradient, in: .circle)
                .opacity(isFallback ? 0.6 : 1)

            Text(name)
                .foregroundStyle(isFallback ? Color.secondary : Color.primary)

            if isFallback {
                Spacer()
                Text("后端兜底")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 单编码模式下把 quality_priority 视为单元素数组。
    private var singleCodecBinding: Binding<CodecID> {
        Binding(
            get: { form.qualityPriority.first ?? .alac },
            set: { form.qualityPriority = [$0] }
        )
    }
}

private struct LyricsSection: View {
    @Binding var form: ConfigForm

    var body: some View {
        Section {
            Toggle("嵌入歌词", isOn: $form.embedLyrics)
            Toggle("保存歌词文件", isOn: $form.saveLyricsFile)
        } footer: {
            Text("嵌入写进音频文件标签；保存文件会在音频旁另存一份歌词。")
        }

        Section("格式") {
            Picker("歌词格式", selection: $form.lyricsFormat) {
                ForEach(ConfigOptions.lyricsFormats, id: \.self) { value in
                    Text(value.uppercased()).tag(value)
                }
            }

            Picker("歌词类型", selection: $form.lyricsType) {
                ForEach(ConfigOptions.lyricsTypes, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        }

        Section {
            ForEach(LyricsExtra.allCases) { extra in
                Toggle(extra.displayName, isOn: lyricsExtraBinding(extra))
            }
        } header: {
            Text("附加内容")
        } footer: {
            Text("需要曲目本身提供对应内容，缺失时自动跳过。")
        }
    }

    private func lyricsExtraBinding(_ extra: LyricsExtra) -> Binding<Bool> {
        Binding(
            get: { form.lyricsExtras.contains(extra) },
            set: { isOn in
                if isOn {
                    if !form.lyricsExtras.contains(extra) { form.lyricsExtras.append(extra) }
                } else {
                    form.lyricsExtras.removeAll { $0 == extra }
                }
            }
        )
    }
}

private struct CoverSection: View {
    @Binding var form: ConfigForm

    private var coverSizeOptions: [String] {
        ConfigOptions.coverSizes.contains(form.coverSize)
            ? ConfigOptions.coverSizes
            : [form.coverSize] + ConfigOptions.coverSizes
    }

    var body: some View {
        Section("规格") {
            Picker("尺寸", selection: $form.coverSize) {
                ForEach(coverSizeOptions, id: \.self) { size in
                    Text(size.replacingOccurrences(of: "x", with: "×")).tag(size)
                }
            }

            Picker("格式", selection: $form.coverFormat) {
                ForEach(ConfigOptions.coverFormats, id: \.self) { value in
                    Text(value.uppercased()).tag(value)
                }
            }
        }

        Section {
            Toggle("嵌入封面", isOn: $form.embedCover)
            Toggle("保存专辑封面文件", isOn: $form.saveAlbumCover)
            Toggle("保存艺人封面文件", isOn: $form.saveArtistCover)
            Toggle("保存歌单封面文件", isOn: $form.savePlaylistCover)
        } header: {
            Text("保存")
        } footer: {
            Text("嵌入写进音频文件标签；保存文件会在对应目录另存一张封面图。")
        }
    }
}

private struct PathsSection: View {
    @Binding var form: ConfigForm

    var body: some View {
        Section("目录") {
            pathField("下载目录", text: $form.downloadsDir)
            pathField("临时目录", text: $form.tempDir)
        }

        Section {
            pathField("单曲", text: $form.songPathFormat)
            pathField("专辑", text: $form.albumPathFormat)
            pathField("艺人", text: $form.artistPathFormat)
            pathField("歌单", text: $form.playlistPathFormat)
            pathField("电台", text: $form.stationPathFormat)
        } header: {
            Text("路径模板")
        } footer: {
            Text("支持变量，如 {ArtistName}、{AlbumName}、{TrackNumber:02d}、{SongName} 等。模板不能为空。")
        }
    }

    /// 模板通常比行宽长，用小号等宽字体并允许折行，避免中间被截断看不到变量。
    private func pathField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
        }
        .padding(.vertical, 4)
    }
}

private struct SimulateSection: View {
    @Binding var form: ConfigForm

    var body: some View {
        Section {
            Toggle("模拟模式", isOn: $form.simulateEnabled)
        } footer: {
            Text("本地测试模式：走完整任务生命周期，但不真正下载、解密或写盘。")
        }

        if form.simulateEnabled {
            Section {
                speedField("最小速度", value: $form.simulateMinKbps, placeholder: "512")
                speedField("最大速度", value: $form.simulateMaxKbps, placeholder: "4096")
            } header: {
                Text("模拟速度")
            } footer: {
                Text("最大速度需 ≥ 最小速度，否则不会保存。")
            }
        }
    }

    private func speedField(_ title: String, value: Binding<Int>, placeholder: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(placeholder, value: value, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 96)
                Text("KB/s")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    RadioView()
}
