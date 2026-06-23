import SwiftUI

/// Simplified trim: cut from start of first video and end of last video only.
struct TrimView: View {
    @Binding var trimSettings: [TrimSettings]
    let videoNames: [String]
    let videoDurations: [TimeInterval]
    var onSeek: ((TimeInterval) -> Void)?
    var isTextFocused: FocusState<Bool>.Binding

    private var totalDuration: TimeInterval {
        videoDurations.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("トリミング")
                    .font(.headline)
                Spacer()
                let trimmedDur = trimmedTotalDuration()
                Text("出力: \(formatTime(trimmedDur)) / \(formatTime(totalDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !trimSettings.isEmpty && !videoDurations.isEmpty {
                // Start trim (first video)
                VStack(alignment: .leading, spacing: 6) {
                    Text("先頭カット")
                        .font(.subheadline.bold())

                    TrimBarView(
                        startTrim: $trimSettings[0].startTrim,
                        endTrim: .constant(0),
                        duration: videoDurations[0],
                        segmentOffset: 0,
                        onSeek: onSeek
                    )
                    .frame(height: 36)

                    trimValueControl(
                        title: "先頭",
                        value: $trimSettings[0].startTrim,
                        maxValue: max(0, videoDurations[0] - trimSettings[0].endTrim - 0.5),
                        onValueChanged: { onSeek?($0) }
                    )
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // End trim (last video)
                if trimSettings.count > 1 {
                    let lastIdx = trimSettings.count - 1
                    let lastOffset = videoDurations[0..<lastIdx].reduce(0, +)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("末尾カット")
                            .font(.subheadline.bold())

                        TrimBarView(
                            startTrim: .constant(0),
                            endTrim: $trimSettings[lastIdx].endTrim,
                            duration: videoDurations[lastIdx],
                            segmentOffset: lastOffset,
                            onSeek: onSeek
                        )
                        .frame(height: 36)

                        trimValueControl(
                            title: "末尾",
                            value: $trimSettings[lastIdx].endTrim,
                            maxValue: max(0, videoDurations[lastIdx] - 0.5),
                            onValueChanged: { onSeek?(lastOffset + videoDurations[lastIdx] - $0) }
                        )
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // Single video: end trim on same video
                    VStack(alignment: .leading, spacing: 6) {
                        Text("末尾カット")
                            .font(.subheadline.bold())

                        TrimBarView(
                            startTrim: .constant(0),
                            endTrim: $trimSettings[0].endTrim,
                            duration: videoDurations[0],
                            segmentOffset: 0,
                            onSeek: onSeek
                        )
                        .frame(height: 36)

                        trimValueControl(
                            title: "末尾",
                            value: $trimSettings[0].endTrim,
                            maxValue: max(0, videoDurations[0] - trimSettings[0].startTrim - 0.5),
                            onValueChanged: { onSeek?(videoDurations[0] - $0) }
                        )
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding()
    }

    private func trimmedTotalDuration() -> TimeInterval {
        guard !trimSettings.isEmpty else { return totalDuration }
        let startTrim = trimSettings.first?.startTrim ?? 0
        let endTrim = trimSettings.last?.endTrim ?? 0
        return max(0, totalDuration - startTrim - endTrim)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func trimValueControl(
        title: String,
        value: Binding<TimeInterval>,
        maxValue: TimeInterval,
        onValueChanged: @escaping (TimeInterval) -> Void
    ) -> some View {
        let binding = clampedTrimBinding(value, maxValue: maxValue, onValueChanged: onValueChanged)

        return HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(formatTime(binding.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)

            TextField("秒", value: binding, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(width: 68)
                .multilineTextAlignment(.trailing)
                .focused(isTextFocused)
                .accessibilityLabel("\(title)カット秒")

            Stepper(title, value: binding, in: 0...max(0, maxValue), step: 0.5)
                .labelsHidden()
                .controlSize(.small)

            Spacer(minLength: 0)

            Button("リセット") {
                binding.wrappedValue = 0
            }
            .font(.caption)
        }
    }

    private func clampedTrimBinding(
        _ value: Binding<TimeInterval>,
        maxValue: TimeInterval,
        onValueChanged: @escaping (TimeInterval) -> Void
    ) -> Binding<TimeInterval> {
        Binding(
            get: { min(max(value.wrappedValue, 0), max(0, maxValue)) },
            set: { newValue in
                let clamped = min(max(newValue, 0), max(0, maxValue))
                value.wrappedValue = clamped
                onValueChanged(clamped)
            }
        )
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
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))

                // Trimmed regions
                if startFrac > 0 {
                    Rectangle().fill(Color.red.opacity(0.25)).frame(width: activeStart)
                }
                if endFrac > 0 {
                    Rectangle().fill(Color.red.opacity(0.25)).frame(width: endFrac * w)
                        .offset(x: activeEnd)
                }

                // Active region border
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: max(activeEnd - activeStart, 0))
                    .offset(x: activeStart)

                // Start handle
                if startTrim >= 0 {
                    TrimHandle(color: .accentColor)
                        .offset(x: activeStart - 6)
                        .gesture(DragGesture().onChanged { value in
                            let frac = max(0, min(value.location.x / w, 1 - endFrac - 0.02))
                            startTrim = Double(frac) * duration
                            onSeek?(segmentOffset + startTrim)
                        })
                }

                // End handle
                if endTrim >= 0 {
                    TrimHandle(color: .accentColor)
                        .offset(x: activeEnd - 6)
                        .gesture(DragGesture().onChanged { value in
                            let frac = max(0, min((w - value.location.x) / w, 1 - startFrac - 0.02))
                            endTrim = Double(frac) * duration
                            onSeek?(segmentOffset + duration - endTrim)
                        })
                }
            }
        }
    }
}

struct TrimHandle: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 12, height: 36)
            .shadow(radius: 2)
    }
}
