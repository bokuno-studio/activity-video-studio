import SwiftUI

/// Export configuration and progress view.
struct ExportView: View {
    @ObservedObject var viewModel: ExportViewModel

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.isExporting {
                exportingView
            } else if viewModel.exportComplete {
                completeView
            } else {
                configView
            }
        }
        .padding()
        .frame(width: 400)
    }

    // MARK: - Config

    private var configView: some View {
        VStack(spacing: 12) {
            Text("エクスポート設定")
                .font(.headline)

            Picker("解像度", selection: $viewModel.resolution) {
                Text("1080p (1920x1080)").tag(ExportViewModel.Resolution.r1080p)
                Text("720p (1280x720)").tag(ExportViewModel.Resolution.r720p)
                Text("4K (3840x2160)").tag(ExportViewModel.Resolution.r4k)
            }

            Picker("品質", selection: $viewModel.quality) {
                Text("高品質").tag(ExportViewModel.Quality.high)
                Text("標準").tag(ExportViewModel.Quality.medium)
                Text("低容量").tag(ExportViewModel.Quality.low)
            }

            if viewModel.videoCount > 1 {
                Toggle("複数動画を結合", isOn: $viewModel.concatenateVideos)
            }

            HStack {
                Button("キャンセル") {
                    viewModel.dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("エクスポート") {
                    viewModel.startExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canExport)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Exporting

    private var exportingView: some View {
        VStack(spacing: 12) {
            Text("エクスポート中...")
                .font(.headline)

            ProgressView(value: viewModel.progress)

            Text(String(format: "%.0f%%", viewModel.progress * 100))
                .font(.title2.monospacedDigit())

            if let msg = viewModel.statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let remaining = viewModel.estimatedRemaining {
                Text("残り約 \(formatTime(remaining))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("キャンセル") {
                viewModel.cancelExport()
            }
        }
    }

    // MARK: - Complete

    private var completeView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("エクスポート完了")
                .font(.headline)

            if let url = viewModel.outputURL {
                Button("Finder で表示") {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                }
            }

            Button("閉じる") {
                viewModel.dismiss()
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        if m > 0 {
            return "\(m)分\(s)秒"
        }
        return "\(s)秒"
    }
}
