//
//  ShazamResultView.swift
//  amdl-ios
//
//  The identified-track screen shown after a successful Shazam match: a blurred
//  album-art backdrop, an artwork hero, track metadata, and the primary actions
//  (enqueue download, add to library, share, Shazam again). The artwork, title,
//  and artist link directly to their matching Apple Music pages.
//

import SwiftUI
import UIKit
import ShazamKit
import MusicKit

struct ShazamResultView: View {
    let item: SHMatchedMediaItem
    let onRestart: () -> Void

    private enum LibraryAddState: Equatable {
        case idle
        case adding
        case added
    }

    private enum DownloadState: Equatable {
        case idle
        case submitting
        case submitted
    }

    private struct AppleMusicDestinations: Equatable {
        var album: URL?
        var song: URL?
        var artist: URL?
    }

    private static let successGradient = LinearGradient(
        colors: [
            Color(red: 0.20, green: 0.66, blue: 0.53),
            Color(red: 0.08, green: 0.42, blue: 0.35)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    @Environment(\.openURL) private var openURL

    @State private var artwork: UIImage?
    @State private var appleMusicDestinations = AppleMusicDestinations()
    @State private var downloadState: DownloadState = .idle
    @State private var libraryState: LibraryAddState = .idle
    @State private var appear = false

    private var shareURL: URL? { item.appleMusicURL ?? item.webURL }
    private var albumURL: URL? {
        appleMusicDestinations.album ?? Self.albumURL(from: item.appleMusicURL)
    }
    private var songURL: URL? {
        appleMusicDestinations.song ?? item.appleMusicURL
    }
    private var artistURL: URL? {
        appleMusicDestinations.artist ?? Self.artistSearchURL(
            artist: item.artist,
            songURL: item.appleMusicURL
        )
    }

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 12)

                artworkHero
                    .scaleEffect(appear ? 1 : 0.92)

                trackInfo
                    .padding(.top, 26)

                Spacer(minLength: 12)

                actions
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .opacity(appear ? 1 : 0)
        }
        .foregroundStyle(.white)
        .task(id: item.artworkURL) {
            await loadArtwork()
        }
        .task(id: item.appleMusicID) {
            await loadAppleMusicDestinations()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                appear = true
            }
        }
    }

    // MARK: - Background

    private var backdrop: some View {
        Group {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 60, opaque: true)
                    .overlay(Color.black.opacity(0.45))
            } else {
                LinearGradient(
                    colors: [ShazamStyle.buttonBottom, .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Foreground pieces

    private var topBar: some View {
        HStack {
            Spacer()
            if let shareURL {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
    }

    @ViewBuilder
    private var artworkHero: some View {
        if let albumURL {
            Button {
                openURL(albumURL)
            } label: {
                artworkHeroContent
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("在 Apple Music 中打开专辑")
        } else {
            artworkHeroContent
        }
    }

    private var artworkHeroContent: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 280)
            .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
    }

    private var trackInfo: some View {
        VStack(spacing: 6) {
            songTitle

            if let artist = item.artist {
                artistName(artist)
            }

            if let genre = item.genres.first {
                Text(genre)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.14), in: Capsule())
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var songTitle: some View {
        let title = Text(item.title ?? "未知歌曲")
            .font(.title2.bold())
            .multilineTextAlignment(.center)
            .lineLimit(2)

        if let songURL {
            Button {
                openURL(songURL)
            } label: {
                title.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("在 Apple Music 中打开歌曲")
        } else {
            title
        }
    }

    @ViewBuilder
    private func artistName(_ artist: String) -> some View {
        let label = Text(artist)
            .font(.title3)
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .lineLimit(1)

        if let artistURL {
            Button {
                openURL(artistURL)
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("在 Apple Music 中打开艺人页")
        } else {
            label
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if let appleMusicURL = item.appleMusicURL {
                Button {
                    submitDownload(appleMusicURL)
                } label: {
                    downloadLabel
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(downloadState != .idle)
            }

            if let appleMusicID = item.appleMusicID {
                Button {
                    addToLibrary(appleMusicID: appleMusicID)
                } label: {
                    addToLibraryLabel
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(libraryState != .idle)
            }

            Button(action: onRestart) {
                capsuleLabel("再次识曲", systemImage: "waveform")
            }
            .buttonStyle(PressableButtonStyle())

            Text("识别能力来自 Shazam")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.vertical, 4)
        }
    }

    private var downloadLabel: some View {
        Group {
            switch downloadState {
            case .idle:
                Label("下载", systemImage: "arrow.down.circle.fill")
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .submitting:
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("正在加入队列…")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .submitted:
                Label("已加入下载队列", systemImage: "checkmark")
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background {
            ZStack {
                Capsule().fill(
                    LinearGradient(
                        colors: [ShazamStyle.buttonTop, ShazamStyle.buttonBottom],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

                Capsule()
                    .fill(Self.successGradient)
                    .opacity(downloadState == .submitted ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.55), value: downloadState)
    }

    private var addToLibraryLabel: some View {
        Group {
            switch libraryState {
            case .idle:
                Label("加入资料库", systemImage: "plus")
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .adding:
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("正在加入…")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .added:
                Label("已加入资料库", systemImage: "checkmark")
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background {
            ZStack {
                Capsule().fill(.white.opacity(0.16))

                Capsule()
                    .fill(Self.successGradient)
                    .opacity(libraryState == .added ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.55), value: libraryState)
    }

    private func capsuleLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(.white.opacity(0.16), in: Capsule())
    }

    // MARK: - Data

    private func loadArtwork() async {
        guard let url = item.artworkURL else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(authorizedURL: url))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return
            }
            guard !Task.isCancelled, let image = UIImage(data: data) else { return }
            artwork = image
        } catch {
            // Leave the placeholder glyph; the backdrop falls back to a gradient.
        }
    }

    private func loadAppleMusicDestinations() async {
        appleMusicDestinations = AppleMusicDestinations()
        guard let appleMusicID = item.appleMusicID else { return }

        do {
            let request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                equalTo: MusicItemID(appleMusicID)
            )
            let response = try await request.response()
            guard let song = response.items.first else { return }
            let resolvedSong = try await song.with(.albums, .artists)
            guard !Task.isCancelled else { return }

            appleMusicDestinations = AppleMusicDestinations(
                album: resolvedSong.albums?.first?.url,
                song: resolvedSong.url,
                artist: resolvedSong.artistURL ?? resolvedSong.artists?.first?.url
            )
        } catch {
            // The Shazam song URL and local Apple Music search remain usable
            // when catalog relationships cannot be loaded.
        }
    }

    /// Apple Music commonly represents a song as its album URL plus an `i`
    /// query item. Removing that item yields the exact album page without a
    /// catalog request. Direct `/song/` URLs are not rewritten.
    private static func albumURL(from songURL: URL?) -> URL? {
        guard let songURL,
              var components = URLComponents(url: songURL, resolvingAgainstBaseURL: false),
              components.path.split(separator: "/").contains("album") else {
            return nil
        }
        components.queryItems = components.queryItems?.filter { $0.name != "i" }
        components.fragment = nil
        return components.url
    }

    /// Until MusicKit returns the canonical primary-artist URL, keep the name
    /// tappable via Apple Music search in the same storefront as the song.
    private static func artistSearchURL(artist: String?, songURL: URL?) -> URL? {
        guard let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines),
              !artist.isEmpty else {
            return nil
        }
        let storefront = songURL?.path.split(separator: "/").first.map(String.init) ?? "us"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.apple.com"
        components.path = "/\(storefront)/search"
        components.queryItems = [URLQueryItem(name: "term", value: artist)]
        return components.url
    }

    private func submitDownload(_ appleMusicURL: URL) {
        downloadState = .submitting

        Task {
            do {
                let mediaUserToken = try await AppleMusicTokenService.currentUserToken()
                let response = try await DownloadsAPI.createDownload(
                    input: appleMusicURL.absoluteString,
                    mediaUserToken: mediaUserToken
                )

                if response.accepted > 0 {
                    downloadState = .submitted
                    return
                }
                if response.firstExistingJobID != nil {
                    downloadState = .submitted
                    return
                }

                downloadState = .idle
                SWAlertManager.shared.show(
                    .error,
                    message: response.firstError ?? "任务未被后端接受"
                )
            } catch {
                downloadState = .idle
                SWAlertManager.shared.show(.error, message: error.localizedDescription)
            }
        }
    }

    private func addToLibrary(appleMusicID: String) {
        libraryState = .adding

        Task {
            do {
                let status = await MusicAuthorization.request()
                guard status == .authorized else {
                    libraryState = .idle
                    SWAlertManager.shared.show(.error, message: "未获得 Apple Music 授权，请在设置中允许访问")
                    return
                }

                let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(appleMusicID))
                let response = try await request.response()

                guard let song = response.items.first else {
                    libraryState = .idle
                    SWAlertManager.shared.show(.error, message: "在 Apple Music 曲库中找不到这首歌")
                    return
                }

                try await MusicLibrary.shared.add(song)
                libraryState = .added
            } catch {
                libraryState = .idle
                SWAlertManager.shared.show(.error, message: "加入资料库失败：\(error.localizedDescription)")
            }
        }
    }
}
