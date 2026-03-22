import SwiftUI

/// Trim settings with visual timeline bar for each video segment.
struct TrimView: View {
    @Binding var trimSettings: [TrimSettings]
    let videoNames: [String]
    let videoDurations: [TimeInterval]
    var onSeek: ((TimeInterval) -> Void)?  // Seek video when trim handle changes

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("トリミング")
                    .font(.headline)
                Spacer()
                // Total trimmed duration
                let totalTrimmed = zip(trimSettings, videoDurations).reduce(0.0) { sum, pair in
                    sum + pair.0.trimmedDuration(original: pair.1)
                }
                Text("合計: \(formatTime(totalTrimmed))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(zip(trimSettings.indices, videoNames)), id: \.0) { index, name in
                if index < trimSettings.count && index < videoDurations.count {
                    let dur = videoDurations[index]
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(name)
                                .font(.subheadline.bold())
                            Spacer()
                            let trimmed = trimSettings[index].trimmedDuration(original: dur)
                            Text("\(formatTime(trimmed)) / \(formatTime(dur))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        // Visual trim bar
                        TrimBarView(
                            startTrim: $trimSettings[index].startTrim,
                            endTrim: $trimSettings[index].endTrim,
                            duration: dur,
                            segmentOffset: videoDurations[0..<index].reduce(0, +),
                            onSeek: onSeek
                        )
                        .frame(height: 40)

                        // Numeric inputs
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("先頭カット")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 4) {
                                    TextField("0", value: $trimSettings[index].startTrim, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                    Text("秒")
                                        .font(.caption)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("末尾カット")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 4) {
                                    TextField("0", value: $trimSettings[index].endTrim, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                    Text("秒")
                                        .font(.caption)
                                }
                            }
                            Spacer()
                            Button("リセット") {
                                trimSettings[index].startTrim = 0
                                trimSettings[index].endTrim = 0
                            }
                            .font(.caption)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Visual bar showing the trim range with draggable handles.
struct TrimBarView: View {
    @Binding var startTrim: TimeInterval
    @Binding var endTrim: TimeInterval
    let duration: TimeInterval
    var segmentOffset: TimeInterval = 0
    var onSeek: ((TimeInterval) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let startFrac = duration > 0 ? CGFloat(startTrim / duration) : 0
            let endFrac = duration > 0 ? CGFloat(endTrim / duration) : 0
            let activeStart = startFrac * w
            let activeEnd = w - endFrac * w

            ZStack(alignment: .leading) {
                // Full bar background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))

                // Trimmed-out regions (dark)
                HStack(spacing: 0) {
                    // Start trim region
                    Rectangle()
                        .fill(Color.red.opacity(0.25))
                        .frame(width: activeStart)

                    Spacer()

                    // End trim region
                    Rectangle()
                        .fill(Color.red.opacity(0.25))
                        .frame(width: endFrac * w)
                }

                // Active region border
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: max(activeEnd - activeStart, 0))
                    .offset(x: activeStart)

                // Start handle
                TrimHandle(color: .orange)
                    .offset(x: activeStart - 6)
                    .gesture(DragGesture()
                        .onChanged { value in
                            let frac = max(0, min(value.location.x / w, 1 - endFrac - 0.02))
                            startTrim = Double(frac) * duration
                            onSeek?(segmentOffset + startTrim)
                        }
                    )

                // End handle
                TrimHandle(color: .orange)
                    .offset(x: activeEnd - 6)
                    .gesture(DragGesture()
                        .onChanged { value in
                            let frac = max(0, min((w - value.location.x) / w, 1 - startFrac - 0.02))
                            endTrim = Double(frac) * duration
                            onSeek?(segmentOffset + duration - endTrim)
                        }
                    )

                // Time labels
                HStack {
                    Text(formatTime(startTrim))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(x: activeStart + 4)
                    Spacer()
                    Text(formatTime(duration - endTrim))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(x: -endFrac * w - 4)
                }
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60; let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct TrimHandle: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 12, height: 40)
            .shadow(radius: 2)
    }
}
