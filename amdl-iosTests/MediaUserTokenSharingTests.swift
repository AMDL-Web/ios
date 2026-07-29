//
//  MediaUserTokenSharingTests.swift
//  amdl-iosTests
//

import Testing
import Foundation
@testable import amdl_ios

/// 分享扩展带上 media user token 这条路上的纯逻辑。
///
/// 钥匙串本身不在这里测：`MediaUserTokenStore` 的读写要靠 App Group 的
/// entitlement 才能生效，而单元测试跑的是 `CODE_SIGNING_ALLOWED=NO` 的构建，
/// 结果取决于环境而不是代码。共享机制本身在线上已经被验证过——分享扩展就是用
/// 同一个 access group 读门户会话的，读不到的话每次分享都会 401。
@Suite struct MediaUserTokenSharingTests {

    // MARK: - 哪些链接需要令牌

    @Test func stationNeedsToken() throws {
        let url = try #require(URL(string: "https://music.apple.com/cn/station/heavy-rotation/ra.978194965"))
        #expect(AppleMusicShareLink.mediaUserTokenNeed(for: url) == .required)
    }

    @Test func betaHostStationNeedsToken() throws {
        let url = try #require(URL(string: "https://beta.music.apple.com/us/station/foo/ra.1"))
        #expect(AppleMusicShareLink.mediaUserTokenNeed(for: url) == .required)
    }

    /// classical 域名下后端根本不收电台，那不是「缺令牌」。照常提交、让后端给出
    /// 真正的原因，比在面板上编一句错的强。
    @Test func classicalStationIsNotBlockedForMissingToken() throws {
        let url = try #require(URL(string: "https://classical.music.apple.com/us/station/foo/ra.1"))
        #expect(AppleMusicShareLink.mediaUserTokenNeed(for: url) == .none)
    }

    @Test func privatePlaylistWantsTokenForArtworkOnly() throws {
        let url = try #require(URL(string: "https://music.apple.com/cn/playlist/mine/pl.u-abc123"))
        #expect(AppleMusicShareLink.mediaUserTokenNeed(for: url) == .artworkOnly)
    }

    @Test func publicPlaylistNeedsNoToken() throws {
        let url = try #require(URL(string: "https://music.apple.com/cn/playlist/todays-hits/pl.abc123"))
        #expect(AppleMusicShareLink.mediaUserTokenNeed(for: url) == .none)
    }

    @Test func albumAndSongNeedNoToken() throws {
        let album = try #require(URL(string: "https://music.apple.com/cn/album/foo/1451245307"))
        let song = try #require(URL(string: "https://music.apple.com/cn/song/foo/1451245310"))
        #expect(AppleMusicShareLink.mediaUserTokenNeed(for: album) == .none)
        #expect(AppleMusicShareLink.mediaUserTokenNeed(for: song) == .none)
    }

    /// 判不出来就不拦。别的主机、缺区域段、路径太短，一律交给后端裁决。
    @Test func unparseableLinksAreNeverBlocked() throws {
        let cases = [
            "https://example.com/cn/station/foo/ra.1",
            "https://music.apple.com/station/ra.1",
            "https://music.apple.com/chn/station/foo/ra.1",
            "https://music.apple.com/cn/station",
        ]
        for raw in cases {
            let url = try #require(URL(string: raw))
            #expect(
                AppleMusicShareLink.mediaUserTokenNeed(for: url) == .none,
                "\(raw) 不该被当成需要令牌"
            )
        }
    }

    // MARK: - 请求体

    @Test func requestCarriesTokenAsOverride() throws {
        let body = try JSONEncoder().encode(
            ShareDownloadCreateRequest(
                url: "https://music.apple.com/cn/station/foo/ra.1",
                mediaUserToken: "user-token"
            )
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["urls"] as? [String] == ["https://music.apple.com/cn/station/foo/ra.1"])
        let overrides = try #require(json["overrides"] as? [String: Any])
        #expect(overrides["media_user_token"] as? String == "user-token")
    }

    /// 后端把 `media_user_token` 当三态：省略＝沿用 fallback，空串＝显式清空。
    /// 没令牌时必须**整个 overrides 都不发**，而不是发一个空串。
    @Test func requestOmitsOverridesEntirelyWithoutToken() throws {
        for token in [nil, "", "   "] as [String?] {
            let body = try JSONEncoder().encode(
                ShareDownloadCreateRequest(
                    url: "https://music.apple.com/cn/album/foo/1",
                    mediaUserToken: token
                )
            )
            let json = try #require(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            #expect(json["overrides"] == nil, "令牌为 \(String(describing: token)) 时不该出现 overrides")
            #expect(json.keys.sorted() == ["urls"])
        }
    }

    @Test func requestTrimsToken() throws {
        let body = try JSONEncoder().encode(
            ShareDownloadCreateRequest(
                url: "https://music.apple.com/cn/station/foo/ra.1",
                mediaUserToken: "  user-token\n"
            )
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let overrides = try #require(json["overrides"] as? [String: Any])
        #expect(overrides["media_user_token"] as? String == "user-token")
    }

    // MARK: - 新旧判定

    @Test func freshTokenIsUsable() {
        let token = SharedMediaUserToken(value: "t", updatedAt: Date())
        #expect(token.isFresh(now: Date()))
    }

    @Test func tokenGoesStaleAfterThreshold() {
        let updatedAt = Date(timeIntervalSince1970: 0)
        let token = SharedMediaUserToken(value: "t", updatedAt: updatedAt)
        let justBefore = updatedAt.addingTimeInterval(SharedMediaUserToken.staleAfter - 1)
        let justAfter = updatedAt.addingTimeInterval(SharedMediaUserToken.staleAfter + 1)
        #expect(token.isFresh(now: justBefore))
        #expect(!token.isFresh(now: justAfter))
    }

    @Test func emptyTokenIsNeverFresh() {
        let token = SharedMediaUserToken(value: "", updatedAt: Date())
        #expect(!token.isFresh(now: Date()))
    }
}
