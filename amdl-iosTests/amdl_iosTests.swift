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

    /// 概览和详情各存各的尺寸，所以谁先拿到图，另一边都得能先借来顶上。
    ///
    /// 借的方向以前只有一个：详情借概览。分享拓展和完成通知走 `amdl://download/<id>`
    /// 深链直接进详情页，概览列表压根没出现过，那张 256 从来没人取过 —— 退回列表
    /// 时没得借，就得从占位图重新等一次。
    @Test @MainActor func artworkFallsBackBetweenOverviewAndHeroSizes() throws {
        let job = try DownloadsAPI.decodeDownloadDetail(from: """
        {
          "job": {
            "id": "job_art", "input": "https://music.apple.com/cn/album/example/1", "type": "album",
            "force": false, "status": "running", "total_items": 1, "done_items": 0, "failed_items": 0,
            "artwork_url": "https://is1-ssl.mzstatic.com/image/thumb/x/{w}x{h}bb.jpg",
            "created_at": "2026-07-30T00:00:00Z", "updated_at": "2026-07-30T00:00:00Z"
          },
          "items": []
        }
        """.data(using: .utf8)!).job

        let overview = JobArtworkLoader.overviewPixelSize
        let hero = JobArtworkLoader.heroPixelSize
        try assert(hero != overview, "hero and overview must be different sizes for this to matter")

        let overviewKey = JobArtworkLoader.cacheKey(for: job, pixelSize: overview)
        let heroKey = JobArtworkLoader.cacheKey(for: job, pixelSize: hero)
        try assert(overviewKey != heroKey, "each size caches separately")

        // 详情 → 概览：这一条以前是 nil，正是深链进来后退回列表要等图的原因。
        try assert(
            JobArtworkLoader.fallbackCacheKey(for: job, pixelSize: overview) == heroKey,
            "overview borrows the hero image"
        )
        // 概览 → 详情：原有方向，不能改坏。
        try assert(
            JobArtworkLoader.fallbackCacheKey(for: job, pixelSize: hero) == overviewKey,
            "hero borrows the overview image"
        )

        // 私人歌单两档尺寸共用一个 key，没有另一份可借，不能自己借自己。
        let privateJob = privatePlaylistJob(
            artworkURL: "https://example-bucket.s3.amazonaws.com/cover.jpg?X-Amz-Expires=86400"
        )
        try assert(
            JobArtworkLoader.fallbackCacheKey(for: privateJob, pixelSize: overview) == nil,
            "a shared cache key has nothing to borrow"
        )
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

    /// 曲目一多，最后一首的零头在均值里就摊得看不见了：200 首下完 199 首是 0.995，
    /// 显示成整数正好是 100% —— 而这时最后一首可能一个字节都还没下。只要还有曲目
    /// 没走完，这个数就得停在 99%。
    @Test func detailProgressStaysBelowFullUntilEveryTrackIsDone() throws {
        func detail(completedTracks: Int, lastTrack status: String) throws -> DownloadDetail {
            let full = #"{"download": 1, "decrypt": 1, "resolved": true, "remuxed": true, "verified": true, "tagged": true, "saved": true}"#
            let untouched = #"{"download": 0, "decrypt": 0, "resolved": false, "remuxed": false, "verified": false, "tagged": false, "saved": false}"#
            let stamps = #""created_at": "2026-07-30T00:00:00Z", "updated_at": "2026-07-30T00:00:00Z""#

            let done = (0..<completedTracks).map { index in
                """
                {"id": "item_\(index)", "job_id": "big_job", "adam_id": "\(index)", "kind": "song",
                 "index": \(index + 1), "status": "completed", "progress": \(full), \(stamps)}
                """
            }
            let last = """
            {"id": "item_last", "job_id": "big_job", "adam_id": "last", "kind": "song",
             "index": \(completedTracks + 1), "status": "\(status)",
             "progress": \(status == "completed" ? full : untouched), \(stamps)}
            """
            let allDone = status == "completed"
            let json = """
            {
              "job": {
                "id": "big_job", "input": "https://music.apple.com/cn/album/1", "type": "album",
                "force": false, "status": "\(allDone ? "completed" : "running")",
                "total_items": \(completedTracks + 1),
                "done_items": \(allDone ? completedTracks + 1 : completedTracks), "failed_items": 0,
                \(stamps)
              },
              "items": [\((done + [last]).joined(separator: ","))]
            }
            """.data(using: .utf8)!
            return try DownloadsAPI.decodeDownloadDetail(from: json)
        }

        // 199/200 还没动最后一首：原始均值 0.995，四舍五入就是 100%。
        let almost = try detail(completedTracks: 199, lastTrack: "queued")
        try assert(almost.progress > 0.9, "199/200 is still nearly done")
        try assert(almost.progress <= 0.99, "199/200 must not round up to 100%")

        // 最后一首也走完了才允许报满。
        let finished = try detail(completedTracks: 199, lastTrack: "completed")
        try assert(finished.progress == 1, "every track done reads as 100%")
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

    @Test func trackSizeEstimatorUsesReducedSharedOverhead() throws {
        var item = try qualityItem(
            codec: "alac",
            bitDepth: 24,
            sampleRate: 96_000,
            bitrate: 800_000
        )
        item.durationMs = 100_000
        item.fileSize = nil

        let estimatedBytes = try #require(
            TrackSizeEstimator.estimatedBytes(for: item, fallbackBitrate: nil)
        )

        // 800 kbps × 100 秒 ÷ 8 = 10 MB，再加调整后的 1.2 MB 元数据补偿。
        try assert(abs(estimatedBytes - 11_200_000) < 0.001, "shared size estimate")
        try assert(
            TrackSizeEstimator.metadataOverheadBytes == 1_200_000,
            "reduced metadata overhead"
        )
    }

    @Test func taskSpeedTrackerAggregatesDownloadAndDecryptAndKeepsTrend() throws {
        var downloading = try speedItem(
            id: "downloading",
            status: "downloading",
            download: 0.1,
            decrypt: 0,
            updatedAt: "2026-07-29T00:00:00Z"
        )
        var decrypting = try speedItem(
            id: "decrypting",
            status: "decrypting",
            download: 1,
            decrypt: 0.2,
            updatedAt: "2026-07-29T00:00:00Z"
        )
        var tracker = TaskSpeedTracker()
        tracker.update(with: [downloading, decrypting])
        try assert(tracker.presentation.downloadingItemCount == 0, "waiting download is not active")
        try assert(tracker.presentation.decryptingItemCount == 0, "waiting decrypt is not active")

        downloading.progress.download = 0.2
        downloading.updatedAt = try #require(
            ISO8601DateFormatter().date(from: "2026-07-29T00:00:02Z")
        )
        decrypting.progress.decrypt = 0.4
        decrypting.updatedAt = downloading.updatedAt
        tracker.update(with: [downloading, decrypting])

        // 每首估算 11.2 MB：下载两秒推进 10%，解密两秒推进 20%。
        try assert(
            abs(tracker.presentation.downloadBytesPerSecond - 560_000) < 0.001,
            "aggregate download speed"
        )
        try assert(
            abs(tracker.presentation.decryptBytesPerSecond - 1_120_000) < 0.001,
            "aggregate decrypt speed"
        )
        try assert(tracker.presentation.downloadingItemCount == 1, "downloading item count")
        try assert(tracker.presentation.decryptingItemCount == 1, "decrypting item count")
        try assert(tracker.presentation.history.count == 2, "trend keeps both samples")
        try assert(
            tracker.presentation.history.last?.downloadBytesPerSecond
                == tracker.presentation.downloadBytesPerSecond,
            "trend records current download speed"
        )
        try assert(
            tracker.presentation.history.last?.decryptBytesPerSecond
                == tracker.presentation.decryptBytesPerSecond,
            "trend records current decrypt speed"
        )
    }

    @Test func transferSpeedFormatUsesFixedMegabytesAndOneDecimalPlace() {
        #expect(TransferSpeedFormat.string(bytesPerSecond: 560_000) == "0.6 MB/s")
        #expect(TransferSpeedFormat.string(bytesPerSecond: 12_340_000) == "12.3 MB/s")
    }

    @Test func taskSpeedTrackerUsesExplicitWaitingStatesForConcurrency() throws {
        let waiting = try speedItem(
            id: "waiting",
            status: "waiting_download",
            download: 0,
            decrypt: 0,
            updatedAt: "2026-07-29T00:00:00Z"
        )
        let downloading = try speedItem(
            id: "downloading",
            status: "downloading",
            download: 0,
            decrypt: 0,
            updatedAt: "2026-07-29T00:00:00Z"
        )
        let decrypting = try speedItem(
            id: "decrypting",
            status: "decrypting",
            download: 1,
            decrypt: 0,
            updatedAt: "2026-07-29T00:00:00Z"
        )
        var tracker = TaskSpeedTracker()
        tracker.update(with: [waiting, downloading, decrypting])

        #expect(waiting.status == .waitingDownload)
        #expect(waiting.status.isActive)
        #expect(waiting.status.text == "等待下载")
        #expect(tracker.presentation.downloadingItemCount == 1)
        #expect(tracker.presentation.decryptingItemCount == 1)
    }

    @Test func taskSpeedTrackerRejectsSubsecondPercentBurstSpikes() throws {
        var item = try speedItem(
            id: "burst",
            status: "downloading",
            download: 0,
            decrypt: 0,
            updatedAt: "2026-07-29T00:00:00Z"
        )
        var tracker = TaskSpeedTracker()
        tracker.update(with: [item])

        // 后端以整数百分比为推送门槛，连续几个事件可能在 20 ms 内成批抵达。11.2 MB
        // 曲目的 1% 若直接除以 20 ms，会凭空显示 5.6 MB/s；它应只进入滚动窗口。
        item.progress.download = 0.01
        item.updatedAt = item.updatedAt.addingTimeInterval(0.02)
        tracker.update(with: [item])
        try assert(
            tracker.presentation.downloadBytesPerSecond == 0,
            "subsecond percent burst must not become a speed"
        )

        item.progress.download = 0.1
        item.updatedAt = try #require(
            ISO8601DateFormatter().date(from: "2026-07-29T00:00:02Z")
        )
        tracker.update(with: [item])
        try assert(
            abs(tracker.presentation.downloadBytesPerSecond - 560_000) < 0.001,
            "rolling window produces the two-second average"
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

    private func speedItem(
        id: String,
        status: String,
        download: Double,
        decrypt: Double,
        updatedAt: String
    ) throws -> JobItem {
        let object: [String: Any] = [
            "id": id,
            "job_id": "speed_job",
            "adam_id": id,
            "kind": "song",
            "index": 1,
            "title": id,
            "duration_ms": 100_000,
            "bitrate": 800_000,
            "status": status,
            "progress": [
                "download": download, "decrypt": decrypt, "resolved": true,
                "remuxed": false, "verified": false, "tagged": false, "saved": false
            ],
            "created_at": "2026-07-29T00:00:00Z",
            "updated_at": updatedAt
        ]
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

    /// 通知里的 Emby 链接来自推送负载，所以它是外部输入。只认 emby 这一个
    /// scheme —— 照单全收就等于让任何能发到这台设备的推送指定一个要打开的 URL。
    @Test func embyDeepLinkAcceptsOnlyTheEmbyScheme() throws {
        let good = try #require(AppDelegate.embyDeepLink(
            fromNotificationUserInfo: ["emby_deep_link": "emby://items?serverId=srv-1&itemId=item-42"]
        ))
        try assert(good.scheme == "emby", "emby scheme is accepted")
        try assert(good.absoluteString.contains("itemId=item-42"), "item id survives")

        for rejected in [
            "https://evil.example/steal",
            "javascript:alert(1)",
            "amdl://download/job_1",
            "   ",
            "",
        ] {
            try assert(
                AppDelegate.embyDeepLink(fromNotificationUserInfo: ["emby_deep_link": rejected]) == nil,
                "rejects \(rejected)"
            )
        }

        // 没有这个键就是常态：非专辑任务、没配 Emby、扫描没跟上都走这一支。
        try assert(
            AppDelegate.embyDeepLink(fromNotificationUserInfo: ["job_id": "job_1"]) == nil,
            "absent key is not an error"
        )
        // 退回路由的依据必须还在。
        try assert(
            AppDelegate.jobID(fromNotificationUserInfo: ["job_id": "job_1"]) == "job_1",
            "job_id still routes in-app"
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

    /// 后端按跨整数百分比发事件，峰值下一秒能来几十个。折线若一个事件一个点，
    /// 36 个点只覆盖约一秒，横轴就没有可比的刻度了。同一秒内的事件必须改写
    /// 当前点而不是各自追加，读数本身仍然每个事件都更新。
    @Test func speedHistoryIsSampledOnceASecondNotOncePerEvent() throws {
        var item = try speedItem(
            id: "t", status: "downloading", download: 0,
            decrypt: 0, updatedAt: "2026-07-29T00:00:00Z"
        )
        var tracker = TaskSpeedTracker()
        tracker.update(with: [item])

        // 十个事件挤在同一秒里。
        for step in 1...10 {
            item.progress.download = Double(step) / 100
            item.updatedAt = try #require(
                ISO8601DateFormatter().date(from: "2026-07-29T00:00:00Z")
            ).addingTimeInterval(Double(step) * 0.05)
            tracker.update(with: [item])
        }
        try assert(tracker.presentation.history.count == 1, "ten sub-second events collapse to one point")

        // 越过节流窗口才追加下一个点。
        item.progress.download = 0.4
        item.updatedAt = try #require(
            ISO8601DateFormatter().date(from: "2026-07-29T00:00:02Z")
        )
        tracker.update(with: [item])
        try assert(tracker.presentation.history.count == 2, "a point past the window appends")

        // 每个点的 id 唯一，Identifiable 的图表才不会错位复用。
        let ids = tracker.presentation.history.map(\.id)
        try assert(Set(ids).count == ids.count, "history ids stay unique")
    }
}

// MARK: - amdl-portal 会话（Milestone 7）

@MainActor
struct GatewayAuthTests {

    /// 三条链路只剩一个可配置的地址。
    ///
    /// 以前默认地址分头写在三个文件里（主 App、实时活动网关、分享扩展），靠人记得
    /// 同步——而漏掉任何一个的后果都不一样地难查：主 App 打错域名会立刻报错，
    /// 但**实时活动网关打错只会静悄悄地再也不出现进度条**，App 那边一句错都不报。
    /// 现在它们都从 `BackendEndpoint` 派生，这个测试钉住那层派生关系。
    @Test func defaultEndpointsPointAtThePortal() {
        // 地址不再硬编码在仓库里：它编译期从 AMDL_PORTAL_HOST 注入，测试 bundle
        // 没有那个键，所以这里断言的是拼装规则本身，而不是某一个部署的地址。
        #expect(BackendEndpoint.defaultBaseURLString(host: "amdl.example.com") == "https://amdl.example.com")
        #expect(BackendEndpoint.defaultBaseURLString(host: "https://amdl.example.com/") == "https://amdl.example.com")
        #expect(BackendEndpoint.defaultBaseURLString(host: "  ") == "")
        #expect(DownloadsAPI.defaultBaseURLString == BackendEndpoint.defaultBaseURLString)
        // 必须保留 /apns 后缀：门户把这个前缀剥掉之后才转给 amdl-ios-gateway，
        // 那台机器只认识 /v1/... 和 /health。
        #expect(BackendEndpoint.apnsURLString(from: "https://amdl.example.com") == "https://amdl.example.com/apns")
        #expect(LiveActivityGatewayAPI.defaultBaseURLString.hasPrefix(DownloadsAPI.defaultBaseURLString))
        // 网关地址就是当前门户地址加前缀，没有第二个存储位置可以和它不一致。
        #expect(LiveActivityGatewayAPI.baseURLString == BackendEndpoint.gatewayBaseURLString)
        #expect(LiveActivityGatewayAPI.baseURLString
            == BackendEndpoint.apnsURLString(from: DownloadsAPI.baseURLString))
    }

    /// 改一个设置，三条链路一起跟着走。
    ///
    /// 这是「一个域名」的全部意义：`/api/v1`（下载）、`/apns`（实时活动）和分享
    /// 扩展读的地址来自同一个 App Group 键。分享扩展是独立二进制，测不进来，但它
    /// 走的是同一份 `BackendEndpoint.baseURLString`（`LiveActivityShared/` 现在也
    /// 编进了那个 target），所以钉住这里就等于钉住了它。
    @Test func oneStoredValueDrivesEveryEndpoint() {
        // 全程走纯函数。**不要往真实 defaults 里写**：用例是并行跑的，塞一个假地址
        // 进去会让同批次里读地址的 `bearerGoesOnlyToThePortalHost` 跟着崩 ——
        // 这个坑在做这次改动时踩过一次。
        let resolve = BackendEndpoint.resolveBaseURLString

        // 没存过值就是内置默认。
        #expect(resolve(nil, nil) == BackendEndpoint.defaultBaseURLString)
        #expect(resolve("", "") == BackendEndpoint.defaultBaseURLString)

        // App Group 里的值优先。分享扩展是独立二进制、测不进来，但它读的就是这一份
        // 代码（`LiveActivityShared/` 现在也编进了那个 target），所以钉住这里等于
        // 钉住了分享扩展。
        #expect(resolve("https://portal.test", nil) == "https://portal.test")
        #expect(resolve("https://portal.test", "https://legacy.test") == "https://portal.test")

        // 更早的版本把地址存在 standard defaults 里，仍然要认。
        #expect(resolve(nil, "https://legacy.test") == "https://legacy.test")
        #expect(resolve("", "https://legacy.test") == "https://legacy.test")

        // 三条链路都从这一个值派生。
        let base = resolve("https://portal.test", nil)
        #expect(BackendEndpoint.apnsURLString(from: base) == "https://portal.test/apns")
    }

    /// 三个调用点读的是同一个值，而且 `/apns` 端点拼在前缀**后面**。
    ///
    /// 这里只读不写，所以设备上当前存着什么地址都成立。端点路径要是覆盖掉前缀
    /// （早先就出过这个 bug），请求会打到 `/v1/...` 而不是 `/apns/v1/...`，
    /// 门户直接 404，而 App 侧一句错都不报。
    @Test func everyCallSiteReadsTheOneSetting() {
        let base = BackendEndpoint.baseURLString
        let gateway = BackendEndpoint.apnsURLString(from: base)

        // Holds whatever the host is, including empty: the point of this test is
        // that there is one setting, not what it contains.
        #expect(DownloadsAPI.baseURLString == base)
        #expect(LiveActivityGatewayAPI.baseURLString == gateway)

        // The `/apns` derivation is checked against an explicit host rather than
        // the ambient one. AMDL_PORTAL_HOST is injected at compile time and is
        // empty in a fresh clone and on CI, and a test that silently asserts a
        // property of the build configuration is worse than no test — that is
        // exactly how these two started failing only on CI.
        let derived = BackendEndpoint.apnsURLString(from: "https://amdl.example.com")
        #expect(derived == "https://amdl.example.com/apns")
        #expect(derived.hasSuffix("/apns"))
        #expect(BackendEndpoint.apnsURLString(from: "https://amdl.example.com/apns") == derived)
        #expect(BackendEndpoint.apnsURLString(from: "") == "")

        guard !gateway.isEmpty else { return }
        #expect(LiveActivityGatewayAPI.makeURL(path: "/v1/devices/abc/push-token")?.absoluteString
            == gateway + "/v1/devices/abc/push-token")
        #expect(LiveActivityGatewayAPI.makeURL(path: "/health")?.absoluteString
            == gateway + "/health")
    }

    /// `/apns` 只加一次，且不受结尾斜杠影响。用户把带前缀的旧地址粘进那个唯一的
    /// 输入框是很可能发生的事，叠成 `/apns/apns` 的话门户会 404。
    @Test func apnsPrefixIsDerivedNotDoubled() {
        #expect(BackendEndpoint.apnsURLString(from: "https://h.example") == "https://h.example/apns")
        #expect(BackendEndpoint.apnsURLString(from: "https://h.example/") == "https://h.example/apns")
        #expect(BackendEndpoint.apnsURLString(from: "https://h.example/apns") == "https://h.example/apns")
        #expect(BackendEndpoint.apnsURLString(from: "https://h.example/apns/") == "https://h.example/apns")
        #expect(BackendEndpoint.apnsURLString(from: "") == "")

        #expect(BackendEndpoint.portalURLString(fromGateway: "https://h.example/apns") == "https://h.example")
        #expect(BackendEndpoint.portalURLString(fromGateway: "https://h.example") == "https://h.example")
    }

    /// 旧版本存下来的独立网关地址怎么并进唯一设置。
    ///
    /// 关键约束是**不能悄悄改掉 `backendBaseURL`**：它管着 /api/v1 和 /api/gw，
    /// 也就是 App 的全部功能。拿网关地址去覆盖它，会把一套本来能用的配置改坏。
    @Test func legacyGatewayURLMigration() {
        typealias Migration = BackendEndpoint.GatewayMigration
        // 内置默认地址现在是编译期注入的，测试 bundle 里为空 —— 显式传进去，
        // 否则这些断言描述的是构建配置而不是迁移逻辑。
        let D = "https://amdl.example.com"

        // 从没存过旧值：绝大多数用户走这条路。
        #expect(BackendEndpoint.gatewayMigration(legacyGateway: nil, storedPortal: nil, builtInDefault: D) == .nothingToDo)
        #expect(BackendEndpoint.gatewayMigration(legacyGateway: "", storedPortal: nil, builtInDefault: D) == .nothingToDo)

        // 两边本来就一致（含只差一个结尾斜杠 / 大小写的情形）：直接删键，无感。
        #expect(BackendEndpoint.gatewayMigration(
            legacyGateway: "https://amdl.example.com/apns", storedPortal: nil, builtInDefault: D
        ) == .droppedRedundantValue)
        #expect(BackendEndpoint.gatewayMigration(
            legacyGateway: "https://amdl.example.com/apns/", storedPortal: "https://amdl.example.com/", builtInDefault: D
        ) == .droppedRedundantValue)

        // 只改过网关、而且旧值是门户形状（带 /apns）：那台主机才是用户指定的，
        // 把 origin 提上来当唯一设置，而不是把他默默退回生产域名。
        #expect(BackendEndpoint.gatewayMigration(
            legacyGateway: "https://staging.example/apns", storedPortal: nil, builtInDefault: D
        ) == .adoptedPortalOrigin("https://staging.example"))

        // 旧值不带 /apns（典型是本地直连网关的调试配置）：它不是门户，不能拿来
        // 当门户地址，只能丢弃并告知。
        #expect(BackendEndpoint.gatewayMigration(
            legacyGateway: "http://192.168.1.5:18081", storedPortal: nil, builtInDefault: D
        ) == .discarded("http://192.168.1.5:18081"))

        // 两个都改过、指向不同主机：一个源站表达不了两个 origin。保留门户地址，
        // 把丢掉的那个记下来让「调试」页明说。
        #expect(BackendEndpoint.gatewayMigration(
            legacyGateway: "http://192.168.1.5:18081", storedPortal: "http://192.168.1.5:18080", builtInDefault: D
        ) == .discarded("http://192.168.1.5:18081"))
        // 同一台主机、门户形状，但门户地址已被改到别处：同样不许覆盖它。
        #expect(BackendEndpoint.gatewayMigration(
            legacyGateway: "https://old.example/apns", storedPortal: "https://new.example", builtInDefault: D
        ) == .discarded("https://old.example/apns"))

        // 迁移结果是 Equatable 的判别式，UI 靠它决定要不要提示。
        let discarded: Migration = .discarded("https://old.example/apns")
        #expect(discarded != .droppedRedundantValue)
    }

    /// 令牌只发给门户域名。封面可能来自 Apple CDN 或对象存储，把会话令牌发给
    /// 第三方既没必要也不安全。
    ///
    /// host 从**当前配置的**门户地址算出来，不写死生产域名：设备上完全可能配着
    /// 本地后端。以前这里写死 `amdl.example.com` 也能过，靠的是网关那份独立的默认
    /// 地址——后端改成 127.0.0.1 之后它仍然是生产域名，于是"生产域名被信任"这条
    /// 断言恰好成立。那正是这次要消掉的分叉，所以断言改成钉住策略本身：**只信任
    /// 配置里的那一个 host，且必须精确匹配**。
    @Test func bearerGoesOnlyToThePortalHost() throws {
        // These hold with no host configured at all, which is the state of a
        // fresh clone and of CI: AMDL_PORTAL_HOST is injected at compile time.
        #expect(!AppleAuthCredentialStore.isGatewayHost("is5-ssl.mzstatic.com"))
        #expect(!AppleAuthCredentialStore.isGatewayHost(nil))
        #expect(!AppleAuthCredentialStore.isGatewayHost(""))

        // The rest describes a configured build. Returning early rather than
        // asserting against an empty host keeps the test honest about what it
        // can see, instead of failing only on CI for the wrong reason.
        guard let host = URLComponents(string: DownloadsAPI.baseURLString)?.host else { return }
        #expect(AppleAuthCredentialStore.isGatewayHost(host))
        #expect(AppleAuthCredentialStore.isGatewayHost(host.uppercased()))
        // 网关走同一个 host，所以派生出来的地址不会引入第二个受信任域名。
        #expect(URLComponents(string: LiveActivityGatewayAPI.baseURLString)?.host == host)
        #expect(!AppleAuthCredentialStore.isGatewayHost("\(host).evil.example"))
    }

    /// 401 是唯一还带着"下一步该做什么"的拒绝，所以它必须被认出来，而不是变成
    /// 一句「服务器错误 (401)」。网关的 401 body 特意用后端那个 `{"error":...}`
    /// 形状，就是为了让客户端只需要一份解码器。
    @Test func unauthenticatedIsRecognisedFromTheErrorBody() throws {
        let decoded = try #require(
            GatewayErrorBody.decode(from: Data(#"{"error":"unauthenticated"}"#.utf8))
        )
        #expect(decoded.resolvedCode == "unauthenticated")
        guard case .needsSignIn = try #require(decoded.authError(status: 401)) else {
            Issue.record("401 unauthenticated 没有被识别出来")
            return
        }
    }

    /// 未知的错误码不许被当成认证问题吞掉——那会把一个真的服务器故障显示成
    /// 「请重新登录」，然后用户反复登录也没用。
    @Test func unknownCodesAreNotTreatedAsAuthErrors() throws {
        let decoded = try #require(
            GatewayErrorBody.decode(from: Data(#"{"error":"queue_full"}"#.utf8))
        )
        #expect(decoded.authError(status: 422) == nil)
    }

    /// 「登录已过期」必须是一句人话，而且要说清楚下一步。**用户会经常看到它** ——
    /// Apple 的 identity token 只活约十分钟且无法静默续期，所以过期是常态。
    @Test func needsSignInHasAComprehensibleMessage() throws {
        let message = try #require(GatewayAuthError.needsSignIn.errorDescription)
        #expect(message.contains("登录"))
        #expect(!message.contains("401"))
        #expect(!message.contains("error"))
    }

    /// 凭据的到期时刻是从 token 自己的 `exp` claim 解出来的，不是"收到时间 + 十分钟"。
    /// 十分钟是实测值不是契约；Apple 改了寿命而这里还按十分钟算，就会带着一个已经
    /// 失效的凭据出门。
    @Test func expiryComesFromTheTokenNotTheClock() throws {
        // exp = 2026-07-30T12:00:00Z。header 和签名都是占位符：这里只解 payload，
        // 验签是网关的事。
        let exp = 1_785_585_600.0
        let payload = try JSONSerialization.data(withJSONObject: ["exp": exp, "aud": "com.example.app"])
        let base64url = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJSUzI1NiJ9.\(base64url).signature"

        let parsed = try #require(GatewayCredential.expiry(ofJWT: token))
        #expect(abs(parsed.timeIntervalSince1970 - exp) < 1)
    }

    /// 解不出 `exp` 时按十分钟兜底，而不是当成"永不过期"。一个不会过期的凭据会让
    /// App 永远不提示重新登录，而每个请求都 401。
    @Test func unparsableTokenFallsBackToTenMinutes() {
        let received = Date()
        for junk in ["", "not-a-jwt", "a.b", "a.!!!.c"] {
            let credential = GatewayCredential(identityToken: junk, receivedAt: received)
            #expect(abs(credential.expiresAt.timeIntervalSince(received) - 600) < 1)
        }
    }

    /// 可用性判断留了余量：卡着到期时刻发出去的请求会在路上过期，白跑一趟 401。
    @Test func credentialNeedsHeadroomBeforeExpiry() {
        // 直接构造，绕开 init 里的 JWT 解析 —— 这里测的是余量，不是解析。
        let almostExpired = GatewayCredential(identityToken: "x", receivedAt: Date().addingTimeInterval(-590))
        let fresh = GatewayCredential(identityToken: "x", receivedAt: Date())
        #expect(!almostExpired.isUsable)
        #expect(fresh.isUsable)
    }

    /// 凭据的编码形状是**跨 target 的契约**：`GatewayCredentialStore` 在主 App
    /// target 里，分享扩展够不着（共享的只有 `LiveActivityShared/`），它自己手抄了
    /// 一份解码器，只认 `identityToken` 和 `expiresAt` 这两个键。改字段名会让分享
    /// 面板静默地不带令牌 —— 提交会 401，而分享面板是个一闪而过的浮层，最难查。
    @Test func storedCredentialKeepsTheKeyNamesTheExtensionReads() throws {
        let encoded = try JSONEncoder().encode(GatewayCredential(identityToken: "token-value"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["identityToken"] as? String == "token-value")
        #expect(object["expiresAt"] != nil)
        // 扩展用默认的 JSONDecoder 解 `expiresAt`，所以编码策略必须是默认的
        // .deferredToDate（自参考日期起的秒数），不能是 ISO8601 字符串。
        #expect(object["expiresAt"] is Double)
    }

    /// Keychain 的 access group 用的是 App Group id。四个 target 的 entitlements
    /// 里已经都有它，所以共享凭据**不需要新增任何 entitlement**——这一点值得钉住，
    /// 因为改 entitlement 要重新配 provisioning。
    @Test func keychainAccessGroupIsTheExistingAppGroup() {
        #expect(GatewayCredentialStore.accessGroup == DownloadsAPI.appGroupIdentifier)
        #expect(GatewayCredentialStore.accessGroup == "group.com.lyjw131.amdl.amdl-ios")
    }

}

/// 任务管理动作：状态 → 可用动作的推导，以及错误措辞。
@MainActor
struct JobActionTests {

    /// 这张表钉的是**后端真实行为**，不是 openapi.yaml 上写的：每一格都在本机起的
    /// amdl-backend 上打过一遍。跑偏了就会给用户一个必定 409 的按钮。
    ///
    /// 最要紧的是 cancelled 那行：`/retry` 只收 failed
    /// （`internal/jobs/manager.go:455`），已取消的任务打过去是
    /// 409 `only failed jobs can be retried`。所以那里给的是 `.restart`
    /// ——重新提交成一个新任务——而不是 `.retry`。
    @Test func availableActionsMirrorTheBackendRules() {
        #expect(JobStatus.queued.availableActions == [.cancel])
        #expect(JobStatus.running.availableActions == [.cancel])
        #expect(JobStatus.completed.availableActions == [.delete])
        #expect(JobStatus.failed.availableActions == [.retry, .delete])
        #expect(JobStatus.cancelled.availableActions == [.restart, .delete])
    }

    /// 已取消的任务绝不能给 `.retry`。单独立一条，因为这正是「文档说 failed
    /// only，但用户想要取消后也能重来」那个需求最容易被做错的地方。
    @Test func cancelledJobsNeverOfferTheRetryEndpoint() {
        #expect(!JobStatus.cancelled.availableActions.contains(.retry))
        #expect(JobStatus.cancelled.availableActions.contains(.restart))
    }

    /// 删除只对终态任务开放（后端 `db.go` 对非终态答 409），
    /// 停止只对活跃任务开放（终态任务后端答 200 但什么也不做）。
    @Test func deleteIsTerminalOnlyAndCancelIsActiveOnly() {
        for status in [JobStatus.queued, .running] {
            #expect(!status.availableActions.contains(.delete), "\(status) 不该能删除")
            #expect(status.availableActions.contains(.cancel), "\(status) 该能停止")
        }
        for status in [JobStatus.completed, .failed, .cancelled] {
            #expect(status.availableActions.contains(.delete), "\(status) 该能删除")
            #expect(!status.availableActions.contains(.cancel), "\(status) 不该能停止")
        }
    }

    /// 侧滑和菜单读同一张表，只是顺序相反（`swipeActions(edge: .trailing)` 里
    /// 先声明的排在最外侧），并且摘掉了删除。
    @Test func swipeOrderIsTheMenuOrderReversedWithoutDelete() {
        for status in [JobStatus.queued, .running, .completed, .failed, .cancelled] {
            let expected: [JobAction] = status.availableActions
                .filter { $0 != .delete }
                .reversed()
            #expect(
                status.trailingSwipeActions == expected,
                "\(status) 的侧滑顺序应当是菜单顺序去掉删除之后的反转"
            )
        }
    }

    /// 删除只能从详情页的 ⋯ 菜单走。侧滑手势离误触太近，不给它。
    @Test func deleteNeverAppearsInTheSwipeGesture() {
        for status in [JobStatus.queued, .running, .completed, .failed, .cancelled] {
            #expect(!status.trailingSwipeActions.contains(.delete), "\(status) 的侧滑不该有删除")
        }
        // 已完成的任务菜单里只有删除，于是它整行都没有侧滑动作。
        #expect(JobStatus.completed.trailingSwipeActions.isEmpty)
    }

    /// 破坏性只有删除一个。取消和重新开始不该被标成破坏性。
    @Test func onlyDeleteIsDestructive() {
        for action in JobAction.allCases {
            #expect(action.isDestructive == (action == .delete))
        }
    }

    /// 配额和状态冲突都要说人话。
    ///
    /// 这不是锦上添花：`/api/v1/*` 的错误体是 `{"error": "..."}`，而
    /// `PortalErrorBody.resolvedMessage` 读的是 `detail/message/title`——一个都没有，
    /// 于是 `DownloadsAPIError.server` 的 `errorDescription` 每次都退化成
    /// 「服务器错误 (409)」。不按状态码翻一遍，用户看到的就只有那句话。
    @Test func actionErrorsGetHumanChineseWording() {
        func mapped(_ status: Int, code: String? = nil, action: JobAction) -> String {
            let error = DownloadsAPIError.server(status: status, code: code, message: nil)
            return JobActionError.mapping(error, action: action).localizedDescription
        }

        // 未翻译时的样子，作为对照：这就是不该让用户看到的那句。
        #expect(
            DownloadsAPIError.server(status: 409, code: "only failed jobs can be retried", message: nil)
                .localizedDescription == "服务器错误 (409)"
        )

        #expect(mapped(429, action: .retry).contains("额度"))
        #expect(mapped(503, action: .retry).contains("排满"))
        #expect(mapped(404, action: .delete).contains("已经不在了"))
        #expect(mapped(409, action: .delete).contains("先「停止」再删除"))
        #expect(mapped(409, action: .retry).contains("只有失败的任务"))

        for action in JobAction.allCases {
            for status in [404, 409, 429, 503] {
                let message = mapped(status, action: action)
                #expect(!message.contains("服务器错误"), "\(action)/\(status) 漏了措辞")
                #expect(!message.isEmpty)
            }
        }
    }

    /// 后端的 `cancelDownload` 把**所有**错误都写成 500，包括「任务不存在」
    /// （`internal/api/server.go:608-614`，delete 和 retry 那两个 handler 都好好
    /// 映射成 404 了）。所以停止一个已经被删掉的任务会收到
    /// 500 `{"error":"job not found"}`，得按错误码认出来。
    @Test func cancelMapsTheBackendsFiveHundredForAMissingJob() {
        let error = DownloadsAPIError.server(status: 500, code: "job not found", message: nil)
        #expect(JobActionError.mapping(error, action: .cancel) as? JobActionError == .jobGone(.cancel))

        // 别的动作、别的 500 一律不认——那些是真的服务器故障。
        #expect(JobActionError.mapping(error, action: .delete) as? JobActionError == nil)
        #expect(
            JobActionError.mapping(
                DownloadsAPIError.server(status: 500, code: "disk full", message: nil),
                action: .cancel
            ) as? JobActionError == nil
        )
    }

    /// 认证类错误本来就有人话，不许被动作层的措辞盖掉。
    @Test func authErrorsPassThroughTheActionMapper() throws {
        let mapped = JobActionError.mapping(GatewayAuthError.needsSignIn, action: .delete)
        guard case GatewayAuthError.needsSignIn = mapped else {
            Issue.record("认证错误被动作层改写了：\(mapped)")
            return
        }
        #expect(mapped.localizedDescription.contains("重新"))
    }
}

// MARK: - 通知点击的深链

/// 点「下载完成」的横幅要落到那个任务的详情页。这条链上 App 这一端有两截：
/// 从 payload 里认出 `job_id`，以及把它交给根视图去导航。
@MainActor
struct NotificationDeepLinkTests {

    /// payload 的形状抄的是网关 `apns.go` 的 `alertPayload`：`job_id` 在顶层，
    /// 不在 `aps` 里。写死这一条，因为两边是手抄的，改名不会有任何东西报错。
    @Test func tapReadsTheJobIDTheGatewayPutsInThePayload() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "专辑下载完成", "body": "Example Album · 共 12 首曲目"], "sound": "default"],
            "event": "job_completed",
            "job_id": "job_01H9",
            "artwork_url": "https://example.com/cover.jpg"
        ]

        #expect(AppDelegate.jobID(fromNotificationUserInfo: userInfo) == "job_01H9")
    }

    /// 认不出任务就别跳：宁可停在原地，也不要把用户丢进一个空的详情页。
    @Test func tapWithoutAUsableJobIDRoutesNowhere() {
        #expect(AppDelegate.jobID(fromNotificationUserInfo: [:]) == nil)
        #expect(AppDelegate.jobID(fromNotificationUserInfo: ["job_id": ""]) == nil)
        #expect(AppDelegate.jobID(fromNotificationUserInfo: ["job_id": "  \n "]) == nil)
        #expect(AppDelegate.jobID(fromNotificationUserInfo: ["job_id": 42]) == nil)
    }

    /// 冷启动的那一半：点击在根视图存在之前就到了，目标必须先存住，等
    /// `ContentView` 能导航了再取——这正是原来跳转被丢掉的地方。
    @Test func aTapBeforeTheRootViewExistsIsHeldUntilItCanNavigate() {
        let route = PendingDownloadRoute.shared
        _ = route.take()

        route.route(toJob: "job_cold")
        #expect(route.jobID == "job_cold", "根视图还没出现时目标必须留着")

        #expect(route.take() == "job_cold")
        // 取过就没了，否则切回下载页会反复把用户弹进同一个详情。
        #expect(route.take() == nil)
        #expect(route.jobID == nil)
    }

}
