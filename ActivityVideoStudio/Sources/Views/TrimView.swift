import SwiftUI

/// Trim settings for each video segment.
struct TrimView: View {
    @Binding var trimSettings: [TrimSettings]
    let videoNames: [String]
    let videoDurations: [TimeInterval]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("トリミング")
                .font(.headline)

            ForEach(Array(zip(trimSettings.indices, videoNames)), id: \.0) { index, name in
                if index < trimSettings.count && index < videoDurations.count {
                    let dur = videoDurations[index]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name)
                            .font(.subheadline.bold())

                        HStack(spacing: 16) {
                            VStack(alignment: .leading) {
                                Text("先頭カット")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Slider(
                                        value: $trimSettings[index].startTrim,
                                        in: 0...max(dur - trimSettings[index].endTrim - 1, 0)
                                    )
                                    Text(formatTime(trimSettings[index].startTrim))
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 55)
                                }
                            }

                            VStack(alignment: .leading) {
                                Text("末尾カット")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Slider(
                                        value: $trimSettings[index].endTrim,
                                        in: 0...max(dur - trimSettings[index].startTrim - 1, 0)
                                    )
                                    Text(formatTime(trimSettings[index].endTrim))
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 55)
                                }
                            }
                        }

                        let trimmed = trimSettings[index].trimmedDuration(original: dur)
                        Text("トリム後: \(formatTime(trimmed)) / 元: \(formatTime(dur))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
