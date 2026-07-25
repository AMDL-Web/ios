//
//  ShazamResultView.swift
//  amdl-ios
//
//  The identified-track screen shown after a successful Shazam match: a blurred
//  album-art backdrop, an artwork hero, track metadata, and the primary actions
//  (open in Apple Music, add to library, view on Shazam, share, Shazam again).
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

    @Environment(\.openURL) private var openURL

    @State private var artwork: UIImage?
    @State private var libraryState: LibraryAddState = .idle
    @State private var appear = false

    private var shareURL: URL? { item.appleMusicURL ?? item.webURL }

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

    private var artworkHero: some View {
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
            Text(item.title ?? "未知歌曲")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if let artist = item.artist {
                Text(artist)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
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

    private var actions: some View {
        VStack(spacing: 12) {
            if let appleMusicURL = item.appleMusicURL {
                Button {
                    openURL(appleMusicURL)
                } label: {
                    capsuleLabel("在 Apple Music 中打开", systemImage: "music.note", filled: true)
                }
                .buttonStyle(PressableButtonStyle())
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
                capsuleLabel("再次识曲", systemImage: "waveform", filled: false)
            }
            .buttonStyle(PressableButtonStyle())

            if let webURL = item.webURL {
                Button {
                    openURL(webURL)
                } label: {
                    Text("在 Shazam 中查看")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var addToLibraryLabel: some View {
        Group {
            switch libraryState {
            case .idle:
                Label("加入资料库", systemImage: "plus")
            case .adding:
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("正在加入…")
                }
            case .added:
                Label("已加入资料库", systemImage: "checkmark")
            }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(.white.opacity(0.16), in: Capsule())
    }

    private func capsuleLabel(_ title: String, systemImage: String, filled: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                if filled {
                    Capsule().fill(
                        LinearGradient(
                            colors: [ShazamStyle.buttonTop, ShazamStyle.buttonBottom],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                } else {
                    Capsule().fill(.white.opacity(0.16))
                }
            }
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
                SWAlertManager.shared.show(.success, message: "已加入资料库")
            } catch {
                libraryState = .idle
                SWAlertManager.shared.show(.error, message: "加入资料库失败：\(error.localizedDescription)")
            }
        }
    }
}
