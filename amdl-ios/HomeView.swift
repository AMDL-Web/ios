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
    @State private var forceOverwrite = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("下载链接") {
                    TextField("Apple Music 链接", text: $input, axis: .vertical)
                        .lineLimit(3...8)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($inputFocused)
                }

                Section("任务选项") {
                    Toggle("覆盖已有文件", isOn: $forceOverwrite)
                }

                Section {
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
                    }
                    .disabled(isSubmitting || trimmedInput.isEmpty)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .pageLargeTitle("新建下载")
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
            let response = try await DownloadsAPI.createDownload(
                input: trimmedInput,
                forceOverwrite: forceOverwrite,
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
