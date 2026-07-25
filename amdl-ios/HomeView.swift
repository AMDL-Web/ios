//
//  HomeView.swift
//  amdl-ios
//
//  Created by 梁杨峻玮 on 2026/7/4.
//

import SwiftUI

struct HomeView: View {
    let onSubmitted: (String?) -> Void

    @State private var input = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            // 只有一个输入框和一个按钮，用 Form 的分组列表会把它们钉在顶部、
            // 中间留一大片空白。改成居中的 VStack，上下用 Spacer 撑开。
            VStack(spacing: 20) {
                Spacer(minLength: 0)

                TextField("Apple Music 链接", text: $input, axis: .vertical)
                    .lineLimit(3...8)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )

                Button(action: submitButtonTapped) {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Label("提交下载", systemImage: "arrow.down.circle.fill")
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || trimmedInput.isEmpty)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .pageLargeTitle("新建下载")
            // 点空白处收起键盘——没有列表可滚动时，键盘会一直挡着按钮。
            .contentShape(Rectangle())
            .onTapGesture { inputFocused = false }
        }
    }

    private func submitButtonTapped() {
        Task {
            await submit()
        }
    }

    private func submit() async {
        guard !trimmedInput.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let mediaUserToken = try await currentMediaUserToken()
            // 不传 forceOverwrite：请求里不带 overrides.force_overwrite，
            // 后端沿用运行时配置 download.force_overwrite。
            let response = try await DownloadsAPI.createDownload(
                input: trimmedInput,
                mediaUserToken: mediaUserToken
            )

            if response.accepted > 0 {
                input = ""
                inputFocused = false
                onSubmitted(response.firstAcceptedJobID)
                return
            }
            if let existingJobID = response.firstExistingJobID {
                inputFocused = false
                onSubmitted(existingJobID)
                return
            }
            errorMessage = response.firstError ?? "任务未被后端接受"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func currentMediaUserToken() async throws -> String? {
        try await AppleMusicTokenService.currentUserToken()
    }
}

#Preview {
    HomeView { _ in }
}
