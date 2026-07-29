//
//  ConfigAPI.swift
//  amdl-ios
//
//  后端运行时配置（GET/PUT /api/v1/config）的模型与网络层。
//  配置页读取整份配置、就地编辑，保存前先 GET 拉取最新再 PUT 回全量，
//  与前端「先取后写、后端深合并」的约定保持一致。
//

import Foundation

// MARK: - 选项枚举

/// 下载编码，对应 download.quality_priority 数组元素。
/// 后端固定在末尾追加不可编辑的 AAC-LC 兜底，这里不含它。
enum CodecID: String, Codable, CaseIterable, Identifiable, Sendable {
    case alac
    case aac
    case aacBinaural = "aac-binaural"
    case aacDownmix = "aac-downmix"
    case ec3
    case ac3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alac: "ALAC（无损）"
        case .aac: "AAC"
        case .aacBinaural: "AAC 双耳"
        case .aacDownmix: "AAC 降混"
        case .ec3: "EC3 / Atmos"
        case .ac3: "AC3"
        }
    }
}

/// download.lyrics_extras 数组元素。
enum LyricsExtra: String, Codable, CaseIterable, Identifiable, Sendable {
    case translation
    case pronunciation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .translation: "翻译"
        case .pronunciation: "注音"
        }
    }
}

// MARK: - 配置模型

/// 后端 /api/v1/config 返回体。
struct ConfigResponse: Codable, Sendable {
    var config: RuntimeConfig
    /// 配置是否已写入磁盘（config.yaml）。false 表示只在内存生效。
    var persisted: Bool?
    /// GET 时若 config.yaml 重新加载失败会带上原因。
    var reloadError: String?

    enum CodingKeys: String, CodingKey {
        case config, persisted
        case reloadError = "reload_error"
    }
}

/// 运行时配置全量对象。所有字段可选，兼容旧后端与部分下发。
struct RuntimeConfig: Codable, Sendable {
    var catalog: CatalogConfig?
    var download: DownloadConfig?
    var logging: LoggingConfig?
    var simulate: SimulateConfig?
}

struct CatalogConfig: Codable, Sendable {
    var albumTrackURLMode: String?
    var mediaUserToken: String?
    var signedModeHLSSource: String?

    enum CodingKeys: String, CodingKey {
        case albumTrackURLMode = "album_track_url_mode"
        case mediaUserToken = "media_user_token"
        case signedModeHLSSource = "signed_mode_hls_source"
    }
}

struct DownloadConfig: Codable, Sendable {
    var qualityPriority: [CodecID]?
    var codecAlternative: Bool?
    var memoryMode: String?
    var maxAttempts: Int?
    var downloadsDir: String?
    var songPathFormat: String?
    var albumPathFormat: String?
    var artistPathFormat: String?
    var playlistPathFormat: String?
    var stationPathFormat: String?
    var tempDir: String?
    var coverSize: String?
    var coverFormat: String?
    var embedCover: Bool?
    var saveAlbumCover: Bool?
    var saveArtistCover: Bool?
    var savePlaylistCover: Bool?
    var embedLyrics: Bool?
    var saveLyricsFile: Bool?
    var lyricsFormat: String?
    var lyricsType: String?
    var lyricsExtras: [LyricsExtra]?
    var alacMaxSampleRate: Int?
    var alacMaxBitDepth: Int?
    var checkIntegrity: Bool?
    var forceOverwrite: Bool?

    enum CodingKeys: String, CodingKey {
        case qualityPriority = "quality_priority"
        case codecAlternative = "codec_alternative"
        case memoryMode = "memory_mode"
        case maxAttempts = "max_attempts"
        case downloadsDir = "downloads_dir"
        case songPathFormat = "song_path_format"
        case albumPathFormat = "album_path_format"
        case artistPathFormat = "artist_path_format"
        case playlistPathFormat = "playlist_path_format"
        case stationPathFormat = "station_path_format"
        case tempDir = "temp_dir"
        case coverSize = "cover_size"
        case coverFormat = "cover_format"
        case embedCover = "embed_cover"
        case saveAlbumCover = "save_album_cover"
        case saveArtistCover = "save_artist_cover"
        case savePlaylistCover = "save_playlist_cover"
        case embedLyrics = "embed_lyrics"
        case saveLyricsFile = "save_lyrics_file"
        case lyricsFormat = "lyrics_format"
        case lyricsType = "lyrics_type"
        case lyricsExtras = "lyrics_extras"
        case alacMaxSampleRate = "alac_max_sample_rate"
        case alacMaxBitDepth = "alac_max_bit_depth"
        case checkIntegrity = "check_integrity"
        case forceOverwrite = "force_overwrite"
    }
}

struct LoggingConfig: Codable, Sendable {
    var level: String?
    var accessLog: Bool?

    enum CodingKeys: String, CodingKey {
        case level
        case accessLog = "access_log"
    }
}

struct SimulateConfig: Codable, Sendable {
    var enabled: Bool?
    var minSpeedKbps: Int?
    var maxSpeedKbps: Int?

    enum CodingKeys: String, CodingKey {
        case enabled
        case minSpeedKbps = "min_speed_kbps"
        case maxSpeedKbps = "max_speed_kbps"
    }
}

// MARK: - 网络层

enum ConfigAPI {
    /// 读取当前配置。后端会先尝试重新加载 config.yaml，再返回最近一次可用配置。
    static func getConfig() async throws -> ConfigResponse {
        let url = try makeURL()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    /// 提交配置。请求体是（可能部分的）RuntimeConfig，后端对缺省键做深合并。
    static func updateConfig(_ config: RuntimeConfig) async throws -> ConfigResponse {
        let url = try makeURL()
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(config)
        return try await send(request)
    }

    /// 探测后端是否处于「本地签名开发者 token」模式。
    ///
    /// 后端没有直接暴露这个状态：catalog.apple_music_private_key_path / key_id /
    /// team_id 三项只在启动时生效，不在 /api/v1/config 的可变视图里。但
    /// /api/v1/developer-token 只有签名模式下才会签发，未开启时固定返回 409，
    /// 所以用它的状态码判断。探测不到（网络失败等）一律当作未开启，宁可少显示
    /// 一个开关，也不要显示一个其实不生效的开关。
    static func signedModeEnabled() async -> Bool {
        guard let url = try? makeURL(path: "/api/v1/developer-token") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let (_, httpResponse) = try? await PortalHTTP.send(request) else {
            return false
        }
        return httpResponse.statusCode == 200
    }

    private static func makeURL(path: String = "/api/v1/config") throws -> URL {
        guard !DownloadsAPI.baseURLString.isEmpty,
              var components = URLComponents(string: DownloadsAPI.baseURLString) else {
            throw DownloadsAPIError.invalidBaseURL
        }
        components.path = path
        guard let url = components.url else {
            throw DownloadsAPIError.invalidBaseURL
        }
        return url
    }

    private static func send(_ request: URLRequest) async throws -> ConfigResponse {
        // 走 PortalHTTP：它续 token、401 后重试一次，并把 403 的 pending_approval
        // 翻成人话。这两个端点在门户策略表里是 **admin only**，所以普通用户会拿到
        // 403 forbidden——那是正确行为，不是 bug。
        let (data, httpResponse) = try await PortalHTTP.send(request)
        guard httpResponse.statusCode == 200 else {
            throw DownloadsAPI.serverError(status: httpResponse.statusCode, data: data)
        }

        var result = try JSONDecoder().decode(ConfigResponse.self, from: data)
        // Go 把 nil slice 序列化成 JSON null，这里统一收敛成空数组，避免下游判空。
        if var download = result.config.download {
            download.qualityPriority = download.qualityPriority ?? []
            download.lyricsExtras = download.lyricsExtras ?? []
            result.config.download = download
        }
        return result
    }
}

private struct ConfigErrorResponse: Decodable {
    let error: String?
    let message: String?
}
