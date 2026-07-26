//
//  DownloadTrackListView.swift
//  amdl-ios
//

import SwiftUI
import UIKit

enum DownloadTrackEdge: Hashable {
    case first
    case last
}

struct DownloadTrackBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: [DownloadTrackEdge: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [DownloadTrackEdge: Anchor<CGRect>],
        nextValue: () -> [DownloadTrackEdge: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct DownloadTrackListView: View {

    let job: Job?
    /// 非 nil 时用竖版出血头图取代方形概览封面。
    var tallHeaderURL: URL? = nil
    var tallHeaderPalette: DownloadDetailPalette? = nil
    let items: [JobItem]
    let progress: Double
    var downloadSpeed: Double = 0
    var decryptSpeed: Double = 0
    let isLoading: Bool
    let hasLoadedDetail: Bool
    let errorMessage: String?
    let palette: DownloadDetailPalette?
    @Binding var presentedQualityDetails: AudioQualityPresentation.Details?

    private var rowBackground: Color? {
        palette == nil ? nil : .clear
    }

    private var albumArtistsAreUniform: Bool {
        let artists = Set(items.compactMap { item -> String? in
            guard let artist = item.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !artist.isEmpty else {
                return nil
            }
            return artist
        })
        return artists.count <= 1
    }

    private var albumTracksOmitSubtitles: Bool {
        job?.type == .album && !items.isEmpty && albumArtistsAreUniform
    }

    private var separatorColor: Color {
        guard let primaryText = palette?.primaryText else {
            return Color(uiColor: .separator)
        }

        let resolvedText = UIColor(primaryText)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolvedText.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return primaryText.opacity(0.131)
        }
        let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
        return (luminance >= 0.5 ? Color.white : Color.black).opacity(0.131)
    }

    @ViewBuilder private var listContent: some View {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let job {
                if let tallHeaderURL, let tallHeaderPalette {
                    Section {
                        MotionArtworkTallHeader(
                            job: job,
                            items: items,
                            presentedQualityDetails: $presentedQualityDetails,
                            videoURL: tallHeaderURL,
                            palette: tallHeaderPalette
                        )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }
                    // 头图和紧随其后的概览是同一段文字节奏，中间不留 section 间距。
                    .listSectionSpacing(0)
                }

                Section {
                    DownloadDetailSummaryView(
                        job: job,
                        hidesArtwork: tallHeaderURL != nil,
                        items: items,
                        progress: progress,
                        downloadSpeed: downloadSpeed,
                        decryptSpeed: decryptSpeed,
                        albumTracksOmitSubtitles: albumTracksOmitSubtitles,
                        palette: palette,
                        presentedQualityDetails: $presentedQualityDetails
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                }

                // 加载指示器放在概览之下（轨道列表的位置），避免首次进入无缓存时
                // 它占住顶部把封面顶低、载入完成后再跳动上移。
                if isLoading && !hasLoadedDetail {
                    loadingSection
                } else {
                    tracksSection(job: job)
                }

                Section {
                    DownloadDetailFooterView(job: job, items: items, palette: palette)
                        .listRowInsets(
                            EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if isLoading && !hasLoadedDetail {
                loadingSection
            }
    }

    var body: some View {
        // 竖版出血头图必须四边贴屏。insetGrouped 会给每个 section 留 16pt 左右边距
        // （实测截图量出 48px @3x），listRowInsets / listSectionMargins / 负 padding
        // 都改不掉——负 padding 还会被行裁掉。plain 样式没有这层边距，是唯一干净的
        // 解法，所以竖版走 plain，方形维持原样。
        Group {
            if tallHeaderURL == nil {
                List { listContent }
            } else {
                List { listContent }.listStyle(.plain)
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(10)
        .scrollContentBackground(palette == nil ? .automatic : .hidden)
        // 竖版出血头图要真正铺到状态栏后面。行内的 ignoresSafeArea 逃不出 List 的
        // 布局，只能让 List 本身放开顶部——列表随之整体上移并从屏幕顶端开始滚动，
        // 和 Apple Music 专辑页的行为一致。
        .ignoresSafeArea(edges: tallHeaderURL == nil ? [] : .top)
        .overlayPreferenceValue(DownloadTrackBoundsPreferenceKey.self) { bounds in
            GeometryReader { proxy in
                if let first = bounds[.first] {
                    separatorLine
                        .padding(.horizontal, 20)
                        .offset(
                            y: proxy[first].minY + (albumTracksOmitSubtitles ? 0 : 1)
                        )
                }
                if let last = bounds[.last] {
                    separatorLine
                        .padding(.horizontal, 20)
                        .offset(y: proxy[last].maxY - 1)
                }
            }
            .allowsHitTesting(false)
        }
        // 概览封面要和 Apple Music 像素级对齐地贴住顶部。原来用
        // `.contentMargins(.top, -16)` 实现，但负的内容内边距会把首个 cell 顶到
        // 滚动边界之上，触发 UICollectionView 丢弃其内容（滚动中封面整块消失）。
        // 改为把内容内边距收到 0（首个 cell 不再越界，消除丢弃），再用负的顶部
        // padding 把整个 List 连同其滚动边界一起上移 16pt——视觉位置与原来完全一致，
        // 但滚动内容始终不越界，所以不再消失。
        .padding(.top, -16)
    }

    private var loadingSection: some View {
        Section {
            HStack {
                Spacer()
                ProgressView("正在载入轨道…")
                Spacer()
            }
            .listRowBackground(rowBackground)
        }
    }

    @ViewBuilder
    private func tracksSection(job: Job) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    DownloadTrackRowView(
                        item: item,
                        jobType: job.type,
                        isFirst: item.id == items.first?.id,
                        isLast: item.id == items.last?.id,
                        albumArtistsAreUniform: albumArtistsAreUniform,
                        separatorColor: separatorColor,
                        palette: palette,
                        presentedQualityDetails: $presentedQualityDetails
                    )
                    .listRowInsets(
                        job.type == .album || job.type.usesCollectionTrackPresentation
                            ? EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
                            : nil
                    )
                    .listRowSeparator(
                        job.type == .album || job.type.usesCollectionTrackPresentation
                            ? .hidden
                            : .automatic
                    )
                    .listRowSeparatorTint(palette?.primaryText.opacity(0.18))
                    .listRowBackground(
                        job.type.usesCollectionTrackPresentation ? Color.clear : rowBackground
                    )
                }
            } header: {
                if job.type != .album && !job.type.usesCollectionTrackPresentation {
                    Text("轨道")
                        .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
                }
            }
        } else if !isLoading {
            Section {
                ContentUnavailableView("暂无轨道明细", systemImage: "music.note.list")
                    .listRowBackground(Color.clear)
            } header: {
                if job.type != .album && !job.type.usesCollectionTrackPresentation {
                    Text("轨道")
                        .foregroundStyle(palette?.tertiaryText ?? Color.secondary)
                }
            }
        }
    }

    private var separatorLine: some View {
        Rectangle()
            .fill(separatorColor)
            .frame(height: 1)
    }
}
