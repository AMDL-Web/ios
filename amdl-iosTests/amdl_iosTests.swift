//
//  amdl_iosTests.swift
//  amdl-iosTests
//
//  Created by 梁杨峻玮 on 2026/7/4.
//

import Testing
import Foundation
@testable import amdl_ios

@MainActor
struct amdl_iosTests {

    @Test @MainActor func privatePlaylistArtworkUsesSignedURLExpiration() throws {
        let url = try #require(URL(string:
            "https://blob.example/artwork?X-Amz-Date=20260722T010203Z&X-Amz-Expires=86400"
        ))
        let expiration = try #require(PrivatePlaylistArtworkStore.signedURLExpiration(url))

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 7
        components.day = 23
        components.hour = 1
        components.minute = 2
        components.second = 3
        try assert(expiration == components.date, "signed URL expiration")
    }

    @Test @MainActor func privatePlaylistArtworkRejectsUnrelatedJobs() throws {
        let job = Job(
            id: "job_1",
            input: "https://music.apple.com/cn/playlist/example/pl.public",
            type: .playlist,
            storefront: "cn",
            title: nil,
            artworkURL: nil,
            force: false,
            status: .running,
            totalItems: 0,
            doneItems: 0,
            failedItems: 0,
            error: nil,
            createdAt: .now,
            updatedAt: .now
        )

        try assert(
            PrivatePlaylistArtworkStore.request(for: job, pixelSize: 256) == nil,
            "public playlist should not use private artwork lookup"
        )
    }

    @Test @MainActor func privatePlaylistS3ArtworkSharesOneCacheAcrossSizes() throws {
        let job = privatePlaylistJob(
            artworkURL: "https://example-bucket.s3.amazonaws.com/cover.jpg?X-Amz-Date=20260722T010203Z&X-Amz-Expires=86400"
        )
        let small = try #require(PrivatePlaylistArtworkStore.request(for: job, pixelSize: 256))
        let large = try #require(PrivatePlaylistArtworkStore.request(for: job, pixelSize: 2048))

        try assert(small.key == large.key, "S3 metadata cache should be shared")
        try assert(small.imageCacheKey == large.imageCacheKey, "S3 image cache should be shared")
        try assert(small.imageCacheKey == "private-playlist:pl.u-private", "stable S3 cache key")
    }

    @Test @MainActor func privatePlaylistArtworkTemplateKeepsSizeSpecificCaches() throws {
        let job = privatePlaylistJob(artworkURL: "https://example.com/{w}x{h}.{f}")
        let small = try #require(PrivatePlaylistArtworkStore.request(for: job, pixelSize: 256))
        let large = try #require(PrivatePlaylistArtworkStore.request(for: job, pixelSize: 2048))

        try assert(small.key != large.key, "template metadata cache should retain size")
        try assert(small.imageCacheKey != large.imageCacheKey, "template image cache should retain size")
    }

    @Test func downloadDetailDecodesJobItems() throws {
        let json = """
        {
          "job": {
            "id": "job_1",
            "input": "https://music.apple.com/cn/album/example/1",
            "type": "album",
            "storefront": "cn",
            "artwork_url": "https://example.com/{w}x{h}.{f}",
            "force": false,
            "status": "running",
            "total_items": 3,
            "done_items": 1,
            "failed_items": 0,
            "created_at": "2026-07-06T07:53:42.431699Z",
            "updated_at": "2026-07-06T07:54:26.066432Z"
          },
          "items": [
            {
              "id": "item_1",
              "job_id": "job_1",
              "adam_id": "100",
              "kind": "song",
              "index": 1,
              "title": "Track One",
              "artist": "Artist",
              "album": "Album",
              "artwork_url": "https://example.com/track/{w}x{h}.{f}",
              "duration_ms": 245000,
              "status": "downloading",
              "progress": {
                "download": 0.5, "decrypt": 0, "resolved": true,
                "remuxed": false, "verified": false, "tagged": false, "saved": false
              },
              "codec": "alac",
              "status_message": "Downloading 50%",
              "created_at": "2026-07-06T07:53:43.446396Z",
              "updated_at": "2026-07-06T07:53:46.585179Z"
            },
            {
              "id": "item_2",
              "job_id": "job_1",
              "adam_id": "101",
              "kind": "song",
              "index": 2,
              "status": "completed",
              "progress": {
                "download": 1, "decrypt": 1, "resolved": true,
                "remuxed": true, "verified": true, "tagged": true, "saved": true
              },
              "created_at": "2026-07-06T07:53:43Z",
              "updated_at": "2026-07-06T07:53:50Z"
            },
            {
              "id": "item_3",
              "job_id": "job_1",
              "adam_id": "102",
              "kind": "song",
              "index": 3,
              "status": "skipped_existing",
              "progress": {
                "download": 0, "decrypt": 0, "resolved": false,
                "remuxed": false, "verified": false, "tagged": false, "saved": false
              },
              "created_at": "2026-07-06T07:53:43Z",
              "updated_at": "2026-07-06T07:53:50Z"
            }
          ]
        }
        """.data(using: .utf8)!

        let detail = try DownloadsAPI.decodeDownloadDetail(from: json)

        try assert(detail.job.id == "job_1", "job id")
        try assert(detail.job.status == .running, "job status")
        try assert(detail.items.count == 3, "item count")
        try assert(detail.items[0].status == .downloading, "first item status")
        try assert(detail.items[0].displayTitle == "Track One", "display title")
        try assert(detail.items[0].subtitle == "Artist · Album", "subtitle")
        try assert(detail.items[0].statusText == "Downloading 50%", "status message")
        try assert(detail.items[2].status == .skippedExisting, "skipped status")
        try assert(detail.items[0].durationMs == 245000, "first item duration")
        try assert(detail.items[1].durationMs == nil, "missing duration decodes to nil")
        // 第一项在下载中途：resolved 的 4% 加上 download 那 56% 的一半。
        // 后两项是终态，clampedProgress 按 status 直接算满格 —— 第三项被跳过，
        // 拆分里全是零值，正是这里要盯住的地方。
        let firstItemFraction = 0.04 + 0.56 * 0.5
        try assert(abs(detail.items[0].clampedProgress - firstItemFraction) < 1e-9, "first item fraction")
        try assert(detail.items[2].clampedProgress == 1, "skipped item reads as complete")
        try assert(abs(detail.progress - (firstItemFraction + 1 + 1) / 3) < 1e-9, "detail progress")
    }

    @Test func trackDurationSummaryFormatsAdaptiveUnits() throws {
        // 无时长（旧后端或未解析）不产生底注片段。
        try assert(TrackDurationSummary.totalDurationText(totalMilliseconds: 0) == nil, "zero → nil")
        // 不足 1 小时用分钟，并四舍五入到最近分钟（3 分 40 秒 → 4 分钟）。
        try assert(
            TrackDurationSummary.totalDurationText(totalMilliseconds: 220_000) == "4 分钟",
            "sub-hour minutes"
        )
        // 跨小时用「X 小时 Y 分钟」。
        try assert(
            TrackDurationSummary.totalDurationText(totalMilliseconds: 3_780_000) == "1 小时 3 分钟",
            "hours and minutes"
        )
        // 整点省略分钟。
        try assert(
            TrackDurationSummary.totalDurationText(totalMilliseconds: 7_200_000) == "2 小时",
            "whole hours omit minutes"
        )
    }

    @Test func songDetailPresentationUsesItemMetadataAndSingleStatus() throws {
        let detail = try songDetail(status: "running", itemStatus: "downloading")
        let item = try #require(detail.items.first)

        try assert(
            SongDetailPresentation.subtitle(item: item) == "Artist — Album",
            "song subtitle"
        )
        try assert(
            SongDetailPresentation.statusText(job: detail.job, item: item) == "下载中",
            "song downloading status"
        )
    }

    @Test func songDetailPresentationFallsBackWithoutMetadataAndSelectsTerminalStatus() throws {
        let completed = try songDetail(status: "completed", itemStatus: "completed", includesMetadata: false)
        let failed = try songDetail(status: "running", itemStatus: "failed", includesMetadata: false)

        try assert(SongDetailPresentation.subtitle(item: completed.items.first) == nil, "empty subtitle fallback")
        try assert(
            SongDetailPresentation.statusText(job: completed.job, item: completed.items.first) == "完成",
            "song completed status"
        )
        try assert(
            SongDetailPresentation.statusText(job: failed.job, item: failed.items.first) == "失败",
            "song failed status"
        )
    }

    @Test func artworkZoomTransitionCoversArtworkFocusedMediaTypes() throws {
        try assert(JobType.song.usesArtworkZoomTransition, "song zoom transition")
        try assert(JobType.album.usesArtworkZoomTransition, "album zoom transition")
        try assert(JobType.playlist.usesArtworkZoomTransition, "playlist zoom transition")
        try assert(JobType.station.usesArtworkZoomTransition, "station zoom transition")
        try assert(!JobType.artist.usesArtworkZoomTransition, "artist should keep default transition")
    }

    @Test func collectionDetailsShareTrackLayoutWithoutArtworkPalette() throws {
        try assert(
            JobType.playlist.usesCollectionTrackPresentation,
            "playlist collection track presentation"
        )
        try assert(
            JobType.station.usesCollectionTrackPresentation,
            "station collection track presentation"
        )
        try assert(!JobType.album.usesCollectionTrackPresentation, "album keeps album track layout")
        try assert(JobType.song.usesArtworkMetadataPalette, "song artwork palette")
        try assert(JobType.album.usesArtworkMetadataPalette, "album artwork palette")
        try assert(!JobType.playlist.usesArtworkMetadataPalette, "playlist uses system colors")
        try assert(!JobType.station.usesArtworkMetadataPalette, "station uses system colors")
    }

    @Test func refreshedDetailPreservesResolvedPresentationMetadata() throws {
        var current = try songDetail(status: "running", itemStatus: "downloading")
        current.job.artworkURL = "https://example.com/cover/{w}x{h}.{f}"
        current.job.artistName = "Artist"
        current.job.genre = "Pop"
        current.job.artworkBgColor = "112233"
        current.items[0].artworkURL = "https://example.com/track/{w}x{h}.{f}"
        current.items[0].codec = "alac"
        current.items[0].sampleRate = 96_000

        var refreshed = current
        refreshed.job.status = .completed
        refreshed.job.doneItems = 1
        refreshed.job.title = nil
        refreshed.job.artworkURL = nil
        refreshed.job.artistName = nil
        refreshed.job.genre = nil
        refreshed.job.artworkBgColor = nil
        refreshed.items[0].status = .completed
        refreshed.items[0].progress.markCompleted()
        refreshed.items[0].title = nil
        refreshed.items[0].artist = nil
        refreshed.items[0].album = nil
        refreshed.items[0].artworkURL = nil
        refreshed.items[0].codec = nil
        refreshed.items[0].sampleRate = nil

        refreshed.preservePresentationMetadata(from: current)

        try assert(refreshed.job.status == .completed, "new job state should win")
        try assert(refreshed.items[0].status == .completed, "new item state should win")
        try assert(refreshed.job.title == "Song", "job title")
        try assert(
            refreshed.job.artworkURL == "https://example.com/cover/{w}x{h}.{f}",
            "job artwork"
        )
        try assert(refreshed.job.artistName == "Artist", "job artist")
        try assert(refreshed.job.genre == "Pop", "job genre")
        try assert(refreshed.job.artworkBgColor == "112233", "job artwork palette")
        try assert(refreshed.items[0].title == "Song", "item title")
        try assert(refreshed.items[0].artist == "Artist", "item artist")
        try assert(refreshed.items[0].album == "Album", "item album")
        try assert(
            refreshed.items[0].artworkURL == "https://example.com/track/{w}x{h}.{f}",
            "item artwork"
        )
        try assert(refreshed.items[0].codec == "alac", "item codec")
        try assert(refreshed.items[0].sampleRate == 96_000, "item sample rate")
    }

    @Test func qualityPresentationKeepsEveryExactTechnicalField() throws {
        let item = try qualityItem(
            codec: "alac",
            bitDepth: 24,
            sampleRate: 96_000,
            bitrate: 2_304_000
        )
        let badges = AudioQualityPresentation.badges(for: item)
        let details = AudioQualityPresentation.details(for: [item], title: "Track · 音质详情")

        try assert(
            badges == [.init(glyph: .hiRes, label: "高解析度无损")],
            "hi-res badge"
        )
        try assert(details.title == "Track · 音质详情", "quality detail title")
        try assert(details.message.contains("编码：ALAC"), "quality codec")
        try assert(details.message.contains("位深度：24 位"), "quality bit depth")
        try assert(
            details.message.contains("采样率：96 kHz"),
            "quality sample rate"
        )
        try assert(
            details.message.contains("码率：2,304 kbps"),
            "quality bitrate"
        )
    }

    @Test func lossyQualityGetsClickableTextBadgeAndPreservesMissingFields() throws {
        let item = try qualityItem(
            codec: "aac-lc",
            bitDepth: nil,
            sampleRate: nil,
            bitrate: 256_000
        )
        let badges = AudioQualityPresentation.badges(for: item)
        let details = AudioQualityPresentation.details(for: [item])

        try assert(
            badges == [.init(glyph: nil, label: "AAC-LC · 256kbps")],
            "lossy quality fallback badge"
        )
        try assert(details.message.contains("位深度：暂无数据"), "missing bit depth")
        try assert(details.message.contains("采样率：暂无数据"), "missing sample rate")
        try assert(
            details.message.contains("码率：256 kbps"),
            "lossy bitrate"
        )
    }

    @Test func completedEventMergesTechnicalQualityFields() throws {
        let data = """
        {
          "job": {
            "id": "job_1", "input": "input", "type": "playlist", "force": false,
            "status": "running", "total_items": 1, "done_items": 0, "failed_items": 0,
            "created_at": "2026-07-20T00:00:00Z", "updated_at": "2026-07-20T00:00:00Z"
          },
          "items": [{
            "id": "item_1", "job_id": "job_1", "adam_id": "1", "kind": "song", "index": 1,
            "title": "Track", "status": "downloading",
            "progress": {"download": 0.9, "decrypt": 0, "resolved": true, "remuxed": false, "verified": false, "tagged": false, "saved": false},
            "created_at": "2026-07-20T00:00:00Z", "updated_at": "2026-07-20T00:00:00Z"
          }],
          "last_event_id": 10
        }
        """.data(using: .utf8)!
        var detail = try DownloadsAPI.decodeDownloadDetail(from: data)
        let payload = """
        {"codec":"alac","bit_depth":24,"sample_rate":96000,"bitrate":2304000}
        """
        let event = DownloadEvent(
            id: 11,
            jobID: "job_1",
            itemID: "item_1",
            type: "item_completed",
            phase: nil,
            message: nil,
            payload: payload
        )

        try assert(detail.apply(event), "completed event should apply")
        try assert(detail.items[0].codec == "alac", "completed codec")
        try assert(detail.items[0].bitDepth == 24, "completed bit depth")
        try assert(detail.items[0].sampleRate == 96_000, "completed sample rate")
        try assert(detail.items[0].bitrate == 2_304_000, "completed bitrate")
    }

    // MARK: - 详细信息

    /// 「详细信息」的全部价值在于补充，重复就没有存在意义。集合任务的底注已经写了
    /// 发行日期、曲目数和创建时间，曲目行也各带音质徽标，所以这些都不能再出现。
    @Test func detailInfoOmitsWhatTheCollectionPageAlreadyShows() throws {
        var job = albumJob(input: "https://music.apple.com/cn/playlist/example/pl.1", type: .playlist)
        job.releaseDate = "2024-03-15"
        let item = try qualityItem(codec: "aac-lc", bitDepth: nil, sampleRate: nil, bitrate: 256_000)
        let labels = DownloadDetailInfo.sections(job: job, items: [item], hooks: [])
            .flatMap { section in section.rows.map(\.label) }

        try assert(!labels.contains("发行日期"), "footer already carries the release date")
        try assert(!labels.contains("创建时间"), "footer already carries the created timestamp")
        try assert(!labels.contains("时长"), "footer already carries the total duration")
        try assert(!labels.contains("编码"), "playlist track rows already carry quality badges")
        try assert(labels.contains("更新时间"), "updated timestamp is shown nowhere else")
        try assert(labels.contains("任务 ID"), "job id is shown nowhere else")
    }

    /// 单曲页只有一张概览卡：没有曲目行也没有底注，所以那部分曲目信息要补齐。
    /// AAC 又不产生音质徽标，四项参数在页面上同样无处可看。
    @Test func detailInfoFillsWhatTheSongPageHasNoRoomFor() throws {
        var detail = try songDetail(status: "completed", itemStatus: "completed")
        detail.job.releaseDate = "2024-03-15"
        detail.items[0].durationMs = 245_000
        detail.items[0].fileSize = 9_800_000
        detail.items[0].codec = "aac-lc"
        detail.items[0].bitrate = 256_000

        let rows = DownloadDetailInfo.sections(job: detail.job, items: detail.items, hooks: [])
            .flatMap(\.rows)
        let value = { (label: String) in rows.first { $0.label == label }?.value }

        try assert(value("专辑") == "Album", "song page never shows the album name")
        try assert(value("时长") == "4:05", "song page never shows the duration")
        // 概览的说明行只给到年份，这里要给出完整日期（长格式随语言环境变，
        // 只断言它确实被解析并重排过，而不是把后端的 YYYY-MM-DD 原样贴出来）。
        try assert(value("发行日期")?.contains("2024") == true, "song page only shows the year")
        try assert(value("发行日期") != "2024-03-15", "raw backend date should be reformatted")
        try assert(value("创建时间") != nil, "song page has no footer timestamp")
        try assert(value("编码") == "AAC-LC", "no badge means no other way to see the codec")
        try assert(value("码率") == "256 kbps", "no badge means no other way to see the bitrate")
        try assert(value("位深度") == nil, "an unavailable field is dropped, not spelled out")
        try assert(value("原始链接") == detail.job.input, "the copy-link payload is never displayed")
    }

    /// 无损单曲的概览带徽标，点一下就是这四项——那就别在表里再列一遍。
    @Test func detailInfoDefersToTheQualityBadgeWhenThereIsOne() throws {
        var detail = try songDetail(status: "completed", itemStatus: "completed")
        detail.items[0].codec = "alac"
        detail.items[0].bitDepth = 24
        detail.items[0].sampleRate = 96_000

        let labels = DownloadDetailInfo.sections(job: detail.job, items: detail.items, hooks: [])
            .flatMap { section in section.rows.map(\.label) }

        try assert(!labels.contains("编码"), "the hi-res badge already opens the quality alert")
        try assert(!labels.contains("采样率"), "the hi-res badge already opens the quality alert")
    }

    /// hook 结果跟着详情快照下发，却是详情页唯一从头到尾没展示过的东西。
    @Test func detailInfoSurfacesHookResults() throws {
        let detail = try songDetail(status: "failed", itemStatus: "failed")
        let hooks = [HookState(name: "notify", status: "failed", error: "connection refused")]
        let rows = DownloadDetailInfo.sections(job: detail.job, items: detail.items, hooks: hooks)
            .flatMap(\.rows)

        try assert(rows.first { $0.label == "notify" }?.value == "失败：connection refused", "hook result")
    }

    private func qualityItem(
        codec: String?,
        bitDepth: Int?,
        sampleRate: Int?,
        bitrate: Int?
    ) throws -> JobItem {
        var object: [String: Any] = [
            "id": "quality_item",
            "job_id": "quality_job",
            "adam_id": "1",
            "kind": "song",
            "index": 1,
            "title": "Track",
            "status": "completed",
            "progress": [
                "download": 1, "decrypt": 1, "resolved": true,
                "remuxed": true, "verified": true, "tagged": true, "saved": true
            ],
            "created_at": "2026-07-20T00:00:00Z",
            "updated_at": "2026-07-20T00:00:00Z"
        ]
        object["codec"] = codec
        object["bit_depth"] = bitDepth
        object["sample_rate"] = sampleRate
        object["bitrate"] = bitrate
        return try DownloadsAPI.decodeJobItem(from: JSONSerialization.data(withJSONObject: object))
    }

    private func songDetail(
        status: String,
        itemStatus: String,
        includesMetadata: Bool = true
    ) throws -> DownloadDetail {
        let metadata = includesMetadata ? "\"title\": \"Song\", \"artist\": \"Artist\", \"album\": \"Album\"," : ""
        let json = """
        {
          "job": {
            "id": "song_job", "input": "https://music.apple.com/cn/song/example/1", "type": "song",
            "title": "Song", "force": false, "status": "\(status)",
            "total_items": 1, "done_items": \(status == "completed" ? 1 : 0), "failed_items": 0,
            "created_at": "2026-07-20T00:00:00Z", "updated_at": "2026-07-20T00:00:00Z"
          },
          "items": [{
            "id": "song_item", "job_id": "song_job", "adam_id": "1", "kind": "song", "index": 1,
            \(metadata)
            "status": "\(itemStatus)",
            "progress": \(itemStatus == "completed"
                ? #"{"download": 1, "decrypt": 1, "resolved": true, "remuxed": true, "verified": true, "tagged": true, "saved": true}"#
                : #"{"download": 0.5, "decrypt": 0, "resolved": true, "remuxed": false, "verified": false, "tagged": false, "saved": false}"#),
            "created_at": "2026-07-20T00:00:00Z", "updated_at": "2026-07-20T00:00:00Z"
          }]
        }
        """.data(using: .utf8)!
        return try DownloadsAPI.decodeDownloadDetail(from: json)
    }

    private func privatePlaylistJob(artworkURL: String?) -> Job {
        Job(
            id: "job_private",
            input: "https://music.apple.com/cn/playlist/example/pl.u-private",
            type: .playlist,
            storefront: "cn",
            title: "Private Playlist",
            artworkURL: artworkURL,
            force: false,
            status: .running,
            totalItems: 0,
            doneItems: 0,
            failedItems: 0,
            error: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @Test func liveActivityStateMatchesGatewayJSONKeys() throws {
        let json = """
        {
          "mode": "single",
          "jobID": "job_1",
          "title": "Example Album",
          "artworkURL": "https://example.com/{w}x{h}.{f}",
          "status": "running",
          "progress": 0.42,
          "activeCount": 1,
          "backendEventID": 1234
        }
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(DownloadActivityAttributes.ContentState.self, from: json)
        try assert(state.mode == "single", "activity mode")
        try assert(state.jobID == "job_1", "activity job id")
        try assert(state.artworkURL == "https://example.com/{w}x{h}.{f}", "activity artwork")
        try assert(state.progress == 0.42, "activity progress")
        try assert(state.activeCount == 1, "activity active count")
        try assert(state.backendEventID == 1234, "activity backend event id")
    }

    @Test func liveActivityResolvesStationCompositeArtworkURL() throws {
        let json = #"""
        {
          "mode": "single",
          "jobID": "station_job",
          "title": "Station",
          "artworkURL": "https://example.com/{w}x{h}.{f}?imgLeft=left\u0026imgRight=right",
          "status": "running",
          "progress": 0.5,
          "activeCount": 1
        }
        """#.data(using: .utf8)!

        let state = try JSONDecoder().decode(
            DownloadActivityAttributes.ContentState.self,
            from: json
        )
        let template = try #require(state.artworkURL)
        try assert(template.contains("&imgRight=right"), "standard JSON URL decoding")

        let resolved = try #require(
            LiveActivityArtworkStore.resolvedRemoteURL(from: template, pixelSize: 384)
        )
        try assert(
            resolved.absoluteString
                == "https://example.com/384x384.jpg?imgLeft=left&imgRight=right",
            "station live activity artwork URL"
        )
    }

    @Test func downloadDetailRejectsOutOfOrderEvents() throws {
        let json = """
        {
          "job": {
            "id": "job_1", "input": "input", "type": "album", "force": false,
            "status": "running", "total_items": 1, "done_items": 0, "failed_items": 0,
            "created_at": "2026-07-20T00:00:00Z", "updated_at": "2026-07-20T00:00:00Z"
          },
          "items": [{
            "id": "item_1", "job_id": "job_1", "adam_id": "1", "kind": "song", "index": 1,
            "status": "downloading",
            "progress": {"download": 0.5, "decrypt": 0, "resolved": true, "remuxed": false, "verified": false, "tagged": false, "saved": false},
            "created_at": "2026-07-20T00:00:00Z", "updated_at": "2026-07-20T00:00:00Z"
          }],
          "last_event_id": 10
        }
        """.data(using: .utf8)!
        var detail = try DownloadsAPI.decodeDownloadDetail(from: json)
        let newer = DownloadEvent(
            id: 12, jobID: "job_1", itemID: "item_1", type: "item_completed",
            phase: nil, message: nil, payload: nil
        )
        let stale = DownloadEvent(
            id: 11, jobID: "job_1", itemID: "item_1", type: "item_failed",
            phase: nil, message: "stale", payload: nil
        )

        try assert(detail.apply(newer), "newer event should apply")
        try assert(!detail.apply(stale), "stale event should be rejected")
        try assert(detail.items[0].status == .completed, "stale event changed item status")
        try assert(detail.lastEventID == 12, "detail event cursor")
    }

    @Test func resolvedInputRefreshesDetailSnapshot() throws {
        let resolved = DownloadEvent(
            id: 12, jobID: "job_1", itemID: nil, type: "resolved_input",
            phase: nil, message: "album", payload: nil
        )
        let progress = DownloadEvent(
            id: 13, jobID: "job_1", itemID: "item_1", type: "item_progress",
            phase: nil, message: nil, payload: nil
        )

        try assert(resolved.requiresDetailSnapshotRefresh, "resolved metadata should refresh detail")
        try assert(!progress.requiresDetailSnapshotRefresh, "progress should stay stream-only")
    }

    @Test func downloadCreateRequestUsesForceOverwriteOverride() throws {
        let request = DownloadCreateRequest(
            input: "https://music.apple.com/cn/album/example/1",
            forceOverwrite: false,
            mediaUserToken: nil
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        let overrides = object?["overrides"] as? [String: Any]

        try assert(object?["force"] == nil, "legacy force field must be omitted")
        try assert(overrides?["force_overwrite"] as? Bool == false, "force overwrite override")
        try assert(overrides?["media_user_token"] == nil, "logged-out request should omit token")
    }

    /// 不传 forceOverwrite 时必须整个键都不出现：后端只要看到
    /// overrides.force_overwrite 就会用它覆盖全局的 download.force_overwrite，
    /// 发一个 false 出去等于把「总配置里开的覆盖」永久顶掉。
    @Test func downloadCreateRequestOmitsForceOverwriteWhenUnset() throws {
        let request = DownloadCreateRequest(
            input: "https://music.apple.com/cn/album/example/1",
            forceOverwrite: nil,
            mediaUserToken: nil
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        let overrides = object?["overrides"] as? [String: Any]

        try assert(overrides?["force_overwrite"] == nil, "unset force overwrite must be omitted entirely")
    }

    @Test func downloadCreateRequestIncludesAuthorizedUserToken() throws {
        let request = DownloadCreateRequest(
            input: "https://music.apple.com/cn/station/example/ra.1",
            forceOverwrite: true,
            mediaUserToken: "user-token"
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        let overrides = object?["overrides"] as? [String: Any]

        try assert(object?["force"] == nil, "legacy force field must be omitted")
        try assert(overrides?["force_overwrite"] as? Bool == true, "force overwrite override")
        try assert(overrides?["media_user_token"] as? String == "user-token", "media user token")
    }

    // MARK: - 动态封面

    /// types 是手工镜像后端 openapi 的，没有任何东西校验两边对齐——键名写错
    /// 只会安静地解不出来，动态封面永远不显示。
    @Test func jobDecodesMotionArtworkKeys() throws {
        let json = """
        {
          "job": {
            "id": "job_1",
            "input": "https://music.apple.com/cn/album/example/1858184006",
            "type": "album",
            "force": false,
            "status": "completed",
            "total_items": 5,
            "done_items": 5,
            "failed_items": 0,
            "created_at": "2026-07-26T00:00:00Z",
            "updated_at": "2026-07-26T00:00:00Z",
            "motion_artwork_url": "https://mvod.example/square.m3u8",
            "motion_artwork_tall_url": "https://mvod.example/tall.m3u8"
          },
          "items": []
        }
        """.data(using: .utf8)!

        let job = try DownloadsAPI.decodeDownloadDetail(from: json).job
        try assert(job.motionArtworkURL == "https://mvod.example/square.m3u8", "square motion artwork")
        try assert(job.motionArtworkTallURL == "https://mvod.example/tall.m3u8", "tall motion artwork")
    }

    /// 后端是异步回填的，绝大多数快照里这两个键根本不存在，不能因此解码失败。
    @Test func jobWithoutMotionArtworkStillDecodes() throws {
        let json = """
        {
          "job": {
            "id": "job_1",
            "input": "https://music.apple.com/cn/playlist/example/pl.1",
            "type": "playlist",
            "force": false,
            "status": "running",
            "total_items": 1,
            "done_items": 0,
            "failed_items": 0,
            "created_at": "2026-07-26T00:00:00Z",
            "updated_at": "2026-07-26T00:00:00Z"
          },
          "items": []
        }
        """.data(using: .utf8)!

        let job = try DownloadsAPI.decodeDownloadDetail(from: json).job
        try assert(job.motionArtworkURL == nil, "absent motion artwork decodes as nil")
    }

    /// 刷新详情快照时后端可能还没写完动态封面。已经在播的封面不能被一次刷新
    /// 打回静态图。
    @Test func refreshPreservesMotionArtworkAcrossAnEmptySnapshot() throws {
        var refreshed = albumJob(input: "https://music.apple.com/cn/album/example/1858184006")
        let previous = {
            var job = albumJob(input: "https://music.apple.com/cn/album/example/1858184006")
            job.motionArtworkURL = "https://mvod.example/square.m3u8"
            return job
        }()

        refreshed.preservePresentationMetadata(from: previous)
        try assert(
            refreshed.motionArtworkURL == "https://mvod.example/square.m3u8",
            "a snapshot without motion artwork must not blank the playing cover"
        )
    }

    /// 和动态封面同理：`artist_url` 是手工镜像后端 openapi 的，键名写错只会安静地
    /// 解不出来，艺人跳转永远退回站内搜索，没人会注意到。
    @Test func jobDecodesArtistURLKey() throws {
        let json = """
        {
          "job": {
            "id": "job_1",
            "input": "https://music.apple.com/cn/album/example/1858184006",
            "type": "album",
            "force": false,
            "status": "completed",
            "total_items": 5,
            "done_items": 5,
            "failed_items": 0,
            "created_at": "2026-07-26T00:00:00Z",
            "updated_at": "2026-07-26T00:00:00Z",
            "artist_name": "星街すいせい",
            "artist_url": "https://music.apple.com/cn/artist/hoshimachi-suisei/1013919"
          },
          "items": []
        }
        """.data(using: .utf8)!

        let job = try DownloadsAPI.decodeDownloadDetail(from: json).job
        try assert(
            job.artistURL == "https://music.apple.com/cn/artist/hoshimachi-suisei/1013919",
            "artist url decodes"
        )
        let destination = try #require(AppleMusicLinks.artistDestination(for: job, name: "星街すいせい"))
        try assert(
            destination.absoluteString == "https://music.apple.com/cn/artist/hoshimachi-suisei/1013919",
            "the decoded url is what the artist tap opens"
        )
    }

    /// 艺人页链接由后端随任务下发（artist_url），点艺人名就直接用它。
    @Test func artistDestinationUsesTheBackendArtistURL() throws {
        var job = albumJob(input: "https://music.apple.com/cn/album/example/1858184006")
        job.artistURL = "https://music.apple.com/cn/artist/example/1013919"
        let url = try #require(AppleMusicLinks.artistDestination(for: job, name: "Example"))
        try assert(
            url.absoluteString == "https://music.apple.com/cn/artist/example/1013919",
            "the backend artist page wins"
        )
    }

    /// `artist_url` 出现之前解析的老任务没有这个字段，退回站内搜艺人名，区域跟着
    /// 任务链接走。
    @Test func artistDestinationFallsBackToSearchWithoutTheField() throws {
        let job = albumJob(input: "https://music.apple.com/cn/album/example/1858184006")
        let url = try #require(AppleMusicLinks.artistDestination(for: job, name: "星街すいせい"))
        let expected = "https://music.apple.com/cn/search?term=%E6%98%9F%E8%A1%97%E3%81%99%E3%81%84%E3%81%9B%E3%81%84"
        try assert(url.absoluteString == expected, "fallback searches the name in the link's storefront")
    }

    /// 歌单/电台的副标题是策展人，没有对应的艺人页，不该做成可点。
    @Test func artistPageIsOfferedOnlyForSongsAndAlbums() throws {
        let playlist = albumJob(input: "https://music.apple.com/cn/playlist/example/pl.1", type: .playlist)
        try assert(!AppleMusicLinks.canOpenArtistPage(for: playlist), "playlists have no artist page")
        try assert(
            AppleMusicLinks.canOpenArtistPage(for: albumJob(input: "https://music.apple.com/cn/album/e/1")),
            "albums have an artist page"
        )
    }

    /// 手输的非链接 input（如 `id:123`）不能做成可点的标题。
    @Test func collectionLinkIgnoresNonWebInput() throws {
        try assert(
            AppleMusicLinks.collectionURL(for: albumJob(input: "id:1858184006")) == nil,
            "non-http input is not a tappable link"
        )
    }

    private func albumJob(input: String, type: JobType = .album) -> Job {
        Job(
            id: "job_album",
            input: input,
            type: type,
            storefront: "cn",
            title: "Example Album",
            artworkURL: nil,
            force: false,
            status: .running,
            totalItems: 0,
            doneItems: 0,
            failedItems: 0,
            error: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func assert(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(message: message)
        }
    }

    private struct TestFailure: Error {
        let message: String
    }
}

// MARK: - amdl-portal 会话（Milestone 7）

@MainActor
struct PortalAuthTests {

    /// 三个默认地址必须一起指向门户。
    ///
    /// 它们分头写在三个文件里（主 App、实时活动网关、分享扩展），历史上就是靠人
    /// 记得同步——而漏掉任何一个的后果都不一样地难查：主 App 打错域名会立刻报错，
    /// 但**实时活动网关打错只会静悄悄地再也不出现进度条**，App 那边一句错都不报。
    @Test func defaultEndpointsPointAtThePortal() {
        #expect(DownloadsAPI.defaultBaseURLString == "https://amdl.lyjw131.com")
        // 必须保留 /apns 后缀：门户把这个前缀剥掉之后才转给 amdl-ios-gateway，
        // 那台机器只认识 /v1/... 和 /health。
        #expect(LiveActivityGatewayAPI.defaultBaseURLString == "https://amdl.lyjw131.com/apns")
        #expect(LiveActivityGatewayAPI.defaultBaseURLString.hasPrefix(DownloadsAPI.defaultBaseURLString))
    }

    /// 令牌只发给门户域名。封面可能来自 Apple CDN 或对象存储，把会话令牌发给
    /// 第三方既没必要也不安全。
    @Test func bearerGoesOnlyToThePortalHost() {
        #expect(AppleAuthCredentialStore.isGatewayHost("amdl.lyjw131.com"))
        #expect(AppleAuthCredentialStore.isGatewayHost("AMDL.LYJW131.COM"))
        #expect(!AppleAuthCredentialStore.isGatewayHost("is5-ssl.mzstatic.com"))
        #expect(!AppleAuthCredentialStore.isGatewayHost("amdl.lyjw131.com.evil.example"))
        #expect(!AppleAuthCredentialStore.isGatewayHost(nil))
        #expect(!AppleAuthCredentialStore.isGatewayHost(""))
    }

    /// 两种错误体形状、同一张码表（DESIGN.md §6.3）。
    ///
    /// `/api/gw/*` 是 problem+json，机器码在 `code`；`/api/v1/*` 保持后端的
    /// `{"error":...}`。客户端只该有一份码表，所以两种都得解得出同一个结论。
    @Test func pendingApprovalIsRecognisedInBothErrorShapes() throws {
        let problemJSON = Data(#"""
        {"type":"about:blank","title":"Forbidden","status":403,
         "detail":"this account is awaiting approval","code":"pending_approval"}
        """#.utf8)
        let mirrorJSON = Data(#"{"error":"pending_approval"}"#.utf8)

        for body in [problemJSON, mirrorJSON] {
            let decoded = try #require(PortalErrorBody.decode(from: body))
            #expect(decoded.resolvedCode == "pending_approval")
            guard case .pendingApproval = try #require(decoded.authError(status: 403)) else {
                Issue.record("403 pending_approval 没有被识别出来")
                return
            }
        }
    }

    /// 「等待批准」必须是一句人话。**每个新用户第一次进来看到的就是它**：门户给
    /// pending 账号也发凭据（好让 App 能调 /api/gw/me 问出自己的状态），别的接口
    /// 一律 403 —— 如果这里只剩「服务器错误 (403)」，用户唯一能得出的结论是登录坏了。
    @Test func pendingApprovalHasAComprehensibleMessage() throws {
        let message = try #require(PortalAuthError.pendingApproval.errorDescription)
        #expect(message.contains("批准"))
        #expect(!message.contains("403"))
        #expect(!message.contains("error"))

        // 停用和登录过期同理：都要说清楚下一步该做什么。
        #expect(try #require(PortalAuthError.suspended.errorDescription).contains("停用"))
        #expect(try #require(PortalAuthError.needsSignIn.errorDescription).contains("登录"))
    }

    /// 未知的错误码不许被当成认证问题吞掉——那会把一个真的服务器故障显示成
    /// 「请重新登录」，然后用户反复登录也没用。
    @Test func unknownCodesAreNotTreatedAsAuthErrors() throws {
        let decoded = try #require(PortalErrorBody.decode(from: Data(#"{"error":"queue_full"}"#.utf8)))
        #expect(decoded.authError(status: 422) == nil)
    }

    /// access token 的可用性判断留了余量：卡着到期时刻发出去的请求会在路上过期，
    /// 白跑一趟 401。
    @Test func accessTokenNeedsHeadroomBeforeExpiry() {
        let almostExpired = PortalCredentials(
            accessToken: "a", refreshToken: "r",
            accessTokenExpiresAt: Date().addingTimeInterval(30)
        )
        let fresh = PortalCredentials(
            accessToken: "a", refreshToken: "r",
            accessTokenExpiresAt: Date().addingTimeInterval(3600)
        )
        #expect(!almostExpired.isAccessTokenUsable)
        #expect(fresh.isAccessTokenUsable)
    }

    /// 凭据的编码形状是**跨 target 的契约**：分享扩展没有共享源码目录，它自己手抄
    /// 了一份解码器，只认 `accessToken` 这个键。改字段名会让分享面板静默地不带令牌。
    @Test func storedCredentialsKeepTheKeyNamesTheExtensionReads() throws {
        let encoded = try JSONEncoder().encode(PortalCredentials(
            accessToken: "token-value", refreshToken: "refresh-value",
            accessTokenExpiresAt: Date()
        ))
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["accessToken"] as? String == "token-value")
        #expect(object["refreshToken"] as? String == "refresh-value")
    }

    /// Keychain 的 access group 用的是 App Group id。四个 target 的 entitlements
    /// 里已经都有它，所以共享凭据**不需要新增任何 entitlement**——这一点值得钉住，
    /// 因为改 entitlement 要重新配 provisioning。
    @Test func keychainAccessGroupIsTheExistingAppGroup() {
        #expect(PortalCredentialStore.accessGroup == DownloadsAPI.appGroupIdentifier)
        #expect(PortalCredentialStore.accessGroup == "group.com.lyjw131.amdl.amdl-ios")
    }
}
