//
//  SWAnimatedMeshGradient.swift
//  amdl-ios
//
//  Adapted from the ShipSwift recipe "Animated Mesh Gradient"
//  (https://shipswift.app · animation/animated-mesh-gradient). The 3x3 mesh
//  smoothly cross-fades between two palettes on a repeating animation. Here it
//  is tuned to a Shazam-blue palette and used as the living background for the
//  识曲 listening screen. Requires iOS 18+ (MeshGradient); the app targets 26.4.
//

import SwiftUI

/// Animated 3x3 `MeshGradient` background that smoothly transitions between two
/// color palettes with a repeating ease-in-out animation. Designed as a
/// full-screen or section background layer.
struct SWAnimatedMeshGradient: View {
    /// First color palette (9 colors, 3x3 grid, row-major order).
    var paletteA: [Color] = [
        Color(red: 0.10, green: 0.16, blue: 0.55), Color(red: 0.09, green: 0.30, blue: 0.80), Color(red: 0.10, green: 0.52, blue: 0.95),
        Color(red: 0.11, green: 0.22, blue: 0.70), Color(red: 0.16, green: 0.42, blue: 0.95), Color(red: 0.10, green: 0.30, blue: 0.82),
        Color(red: 0.10, green: 0.50, blue: 0.92), Color(red: 0.10, green: 0.26, blue: 0.72), Color(red: 0.14, green: 0.14, blue: 0.52)
    ]

    /// Second color palette (9 colors, 3x3 grid, row-major order).
    var paletteB: [Color] = [
        Color(red: 0.10, green: 0.50, blue: 0.92), Color(red: 0.11, green: 0.22, blue: 0.70), Color(red: 0.16, green: 0.42, blue: 0.95),
        Color(red: 0.14, green: 0.14, blue: 0.52), Color(red: 0.10, green: 0.36, blue: 0.88), Color(red: 0.10, green: 0.52, blue: 0.95),
        Color(red: 0.09, green: 0.30, blue: 0.80), Color(red: 0.10, green: 0.50, blue: 0.92), Color(red: 0.11, green: 0.20, blue: 0.62)
    ]

    /// Animation cycle duration in seconds.
    var duration: Double = 6.0

    @State private var appear = false

    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            .init(0, 0), .init(0.5, 0), .init(1, 0),
            .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
            .init(0, 1), .init(0.5, 1), .init(1, 1)
        ], colors: appear ? paletteA : paletteB)
        .onAppear {
            withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                appear = true
            }
        }
    }
}

#Preview {
    SWAnimatedMeshGradient()
        .ignoresSafeArea()
}
