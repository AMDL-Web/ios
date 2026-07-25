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
              "progress": 0.5,
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
              "progress": 1,
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
              "progress": 1,
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
        try assert(detail.progress == (0.5 + 1 + 1) / 3, "detail progress")
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
        refreshed.items[0].progress = 1
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
            "title": "Track", "status": "downloading", "progress": 0.9,
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
            "progress": 1,
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
            "status": "\(itemStatus)", "progress": \(itemStatus == "completed" ? 1 : 0.5),
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
            "status": "downloading", "progress": 0.5,
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

    private func assert(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(message: message)
        }
    }

    private struct TestFailure: Error {
        let message: String
    }
}
