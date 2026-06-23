import SwiftUI

/// Sidebar showing loaded files and their metadata.
struct FileListView: View {
    let fitURL: URL?
    let fitPointCount: Int
    let videoURLs: [URL]
    let videoDurations: [TimeInterval]
    let onRemoveVideo: (Int) -> Void

    var body: some View {
        List {
            // FIT file
            Section("FIT ファイル") {
                if let url = fitURL {
                    HStack {
                        Image(systemName: "waveform.path")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent)
                                .font(.subheadline)
                            Text("\(fitPointCount) データポイント")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("FITファイル \(url.lastPathComponent)、\(fitPointCount) データポイント")
                } else {
                    Text(".fit ファイルをドロップ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Videos
            Section("動画ファイル (\(videoURLs.count))") {
                if videoURLs.isEmpty {
                    Text(".mp4 / .mov ファイルをドロップ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(videoURLs.enumerated()), id: \.offset) { index, url in
                    HStack {
                        Image(systemName: "film")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent)
                                .font(.subheadline)
                            if index < videoDurations.count {
                                Text(formatDuration(videoDurations[index]))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("#\(index + 1)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(videoAccessibilityLabel(index: index, url: url))
                    .contextMenu {
                        Button(role: .destructive) {
                            onRemoveVideo(index)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func videoAccessibilityLabel(index: Int, url: URL) -> String {
        if index < videoDurations.count {
            return "動画\(index + 1)、\(url.lastPathComponent)、\(formatDuration(videoDurations[index]))"
        }
        return "動画\(index + 1)、\(url.lastPathComponent)"
    }
}
