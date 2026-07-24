//
//  ShazamView.swift
//  amdl-ios
//
//  Created by OpenAI on 2026/7/5.
//  Redesigned as an immersive, Apple-Shazam-style recognition screen: a living
//  mesh-gradient background, a pulsing tap-to-Shazam button with concentric
//  ripple rings, and a rich result screen. The ShazamKit matching logic is
//  unchanged from the working implementation.
//

import SwiftUI
import ShazamKit

/// Shared visual constants for the 识曲 experience.
enum ShazamStyle {
    /// The Shazam-blue button gradient endpoints.
    static let buttonTop = Color(red: 0.30, green: 0.62, blue: 1.00)
    static let buttonBottom = Color(red: 0.03, green: 0.24, blue: 0.82)
    /// Accent used for glows and primary actions.
    static let accent = Color(red: 0.16, green: 0.52, blue: 1.00)
}

struct ShazamView: View {
    /// The recognition screen's coarse state. `matched` reads the identified
    /// track from `match`; keeping the media item out of the enum lets `Phase`
    /// stay `Equatable` for animation and sensory-feedback triggers.
    enum Phase: Equatable {
        case idle
        case listening
        case matched
        case noMatch
        case error(String)
    }

    @State private var phase: Phase = .idle
    @State private var match: SHMatchedMediaItem?
    @State private var session: SHManagedSession?
    @State private var matchTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if phase == .matched, let match {
                ShazamResultView(item: match, onRestart: restart)
                    .transition(.opacity)
            } else {
                ShazamHeroView(phase: phase, onToggle: toggleMatching)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
        .swAlert()
        .sensoryFeedback(trigger: phase) { _, newPhase -> SensoryFeedback? in
            switch newPhase {
            case .matched: return .success
            case .noMatch, .error: return .warning
            case .listening: return .selection
            case .idle: return nil
            }
        }
        .onDisappear {
            stopMatching()
        }
    }

    // MARK: - Actions

    private func toggleMatching() {
        if phase == .listening {
            stopMatching()
        } else {
            startMatching()
        }
    }

    private func restart() {
        match = nil
        phase = .idle
    }

    private func startMatching() {
        stopMatching(resetToIdle: false)

        let newSession = SHManagedSession()
        session = newSession
        match = nil
        phase = .listening

        matchTask = Task {
            await newSession.prepare()
            let result = await newSession.result()

            if Task.isCancelled { return }

            await MainActor.run {
                handle(result)
            }
        }
    }

    private func stopMatching(resetToIdle: Bool = true) {
        matchTask?.cancel()
        matchTask = nil
        session?.cancel()
        session = nil

        if resetToIdle, phase == .listening {
            phase = .idle
        }
    }

    private func handle(_ result: SHSession.Result) {
        session = nil
        matchTask = nil

        switch result {
        case .match(let match):
            if let item = match.mediaItems.first {
                self.match = item
                phase = .matched
            } else {
                phase = .noMatch
            }
        case .noMatch:
            phase = .noMatch
        case .error(let error, _):
            phase = .error(error.localizedDescription)
        }
    }
}

// MARK: - Hero (idle / listening / no-match / error)

private struct ShazamHeroView: View {
    let phase: ShazamView.Phase
    let onToggle: () -> Void

    private let buttonDiameter: CGFloat = 208

    private var isListening: Bool { phase == .listening }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            SWAnimatedMeshGradient()
                .ignoresSafeArea()
                .saturation(isListening ? 1.1 : 0.82)
                .animation(.easeInOut(duration: 0.6), value: isListening)

            // Vignette + adaptive dimming keep white copy legible over the
            // moving gradient and calm the field down when idle.
            LinearGradient(
                colors: [.black.opacity(0.32), .clear, .black.opacity(0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .overlay {
                Color.black
                    .opacity(isListening ? 0.04 : 0.22)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.6), value: isListening)
            }

            VStack(spacing: 0) {
                header

                Spacer(minLength: 0)

                buttonCluster

                statusText
                    .padding(.top, 44)
                    .padding(.horizontal, 24)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
        }
    }

    private var header: some View {
        HStack {
            Text("识曲")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Spacer()
        }
    }

    private var buttonCluster: some View {
        ZStack {
            if isListening {
                PulseRings(diameter: buttonDiameter)
                    .transition(.opacity)
            }
            ShazamButton(isListening: isListening, diameter: buttonDiameter, action: onToggle)
        }
        .frame(height: buttonDiameter)
    }

    private var statusText: some View {
        VStack(spacing: 8) {
            Text(statusTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)

            if let statusSubtitle {
                Text(statusSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: phase)
    }

    private var statusTitle: String {
        switch phase {
        case .idle: "轻点识曲"
        case .listening: "正在聆听…"
        case .noMatch: "未能识别"
        case .error: "识别出错"
        case .matched: ""
        }
    }

    private var statusSubtitle: String? {
        switch phase {
        case .idle: "识别正在播放的音乐"
        case .listening: "请让设备靠近音乐"
        case .noMatch: "确保音乐清晰可辨，然后轻点重试"
        case .error(let message): message
        case .matched: nil
        }
    }
}

// MARK: - Shazam button

private struct ShazamButton: View {
    let isListening: Bool
    let diameter: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [ShazamStyle.buttonTop, ShazamStyle.buttonBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    }
                    .shadow(color: ShazamStyle.accent.opacity(0.55), radius: 28, y: 12)

                Image(systemName: "waveform")
                    .font(.system(size: diameter * 0.42, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: isListening)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Pulsing ripple rings

/// Concentric rings that expand outward and fade, evenly staggered. Driven by a
/// `TimelineView` so the phase is deterministic and the rings never visibly
/// jump — mounted only while listening.
private struct PulseRings: View {
    let diameter: CGFloat
    var color: Color = .white

    private let ringCount = 4
    private let period: Double = 3.0

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            ZStack {
                ForEach(0..<ringCount, id: \.self) { index in
                    let raw = elapsed / period + Double(index) / Double(ringCount)
                    let phase = raw - raw.rounded(.down) // fractional part, 0..<1
                    Circle()
                        .stroke(color.opacity((1.0 - phase) * 0.45), lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(1.0 + phase * 1.4)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ShazamView()
}
