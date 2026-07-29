//
//  PageLargeTitle.swift
//  amdl-ios
//
//  Created by OpenAI on 2026/7/5.
//

import SwiftUI

extension View {
    /// 仿 Apple Music 的紧凑大标题：隐藏系统导航栏，标题直接放在状态栏下方，
    /// 可选在标题行尾部放按钮。内容上滑顶到标题时，标题会在短距离内渐隐。
    func pageLargeTitle(
        _ title: String,
        color: Color = .primary,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        modifier(PageLargeTitleModifier(title: title, color: color, trailing: trailing()))
    }
}

private struct PageLargeTitleModifier<Trailing: View>: ViewModifier {
    let title: String
    let color: Color
    let trailing: Trailing

    /// 内容相对静止位置的上滑距离
    @State private var scrollOffset: CGFloat = 0

    /// 内容开始侵入标题区域后，在短距离内从 1 渐隐到 0
    private var titleOpacity: CGFloat {
        let fadeStart: CGFloat = 6
        let fadeDistance: CGFloat = 28
        return 1 - min(max((scrollOffset - fadeStart) / fadeDistance, 0), 1)
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newValue in
                scrollOffset = newValue
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(alignment: .center) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(color)
                        .opacity(titleOpacity)

                    Spacer()

                    trailing
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
    }
}
