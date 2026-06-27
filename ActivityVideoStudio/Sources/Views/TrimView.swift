import SwiftUI
import Foundation

/// Simplified trim: cut from start of first video and end of last video only.
struct TrimView: View {
    @Binding var trimSettings: [TrimSettings]
    let videoNames: [String]
    let videoDurations: [TimeInterval]
    var onPreviewSeek: ((TimeInterval) -> Void)?
    var onCommitSeek: ((TimeInterval) -> Void)?
    /// Reports whether any trim time field is currently being edited, so the
    /// parent can suspend playback keyboard shortcuts while the user is typing.
    var onEditingChanged: (Bool) -> Void = { _ in }

    @FocusState private var focusedField: String?

    private static let durationFormatter = TrimDurationFormatter()

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
                        onPreviewSeek: onPreviewSeek,
                        onCommitSeek: onCommitSeek
                    )
                    .frame(height: 36)

                    trimValueControl(
                        title: "先頭",
                        value: $trimSettings[0].startTrim,
                        maxValue: max(0, videoDurations[0] - trimSettings[0].endTrim - 0.5),
                        seekTime: { $0 }
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
                            onPreviewSeek: onPreviewSeek,
                            onCommitSeek: onCommitSeek
                        )
                        .frame(height: 36)

                        trimValueControl(
                            title: "末尾",
                            value: $trimSettings[lastIdx].endTrim,
                            maxValue: max(0, videoDurations[lastIdx] - 0.5),
                            seekTime: { lastOffset + videoDurations[lastIdx] - $0 }
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
                            onPreviewSeek: onPreviewSeek,
                            onCommitSeek: onCommitSeek
                        )
                        .frame(height: 36)

                        trimValueControl(
                            title: "末尾",
                            value: $trimSettings[0].endTrim,
                            maxValue: max(0, videoDurations[0] - trimSettings[0].startTrim - 0.5),
                            seekTime: { videoDurations[0] - $0 }
                        )
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = nil
        }
        .onChange(of: focusedField) { _, field in
            onEditingChanged(field != nil)
        }
    }

    private func trimmedTotalDuration() -> TimeInterval {
        guard !trimSettings.isEmpty else { return totalDuration }
        let startTrim = trimSettings.first?.startTrim ?? 0
        let endTrim = trimSettings.last?.endTrim ?? 0
        return max(0, totalDuration - startTrim - endTrim)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let total = tenths / 10
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let fraction = tenths % 10
        let secondsText = fraction == 0 ? "\(s)秒" : "\(s).\(fraction)秒"
        if h > 0 { return "\(h)時間\(m)分\(secondsText)" }
        if m > 0 { return "\(m)分\(secondsText)" }
        return secondsText
    }

    private func trimValueControl(
        title: String,
        value: Binding<TimeInterval>,
        maxValue: TimeInterval,
        seekTime: @escaping (TimeInterval) -> TimeInterval
    ) -> some View {
        let binding = clampedTrimBinding(value, maxValue: maxValue) { newValue in
            onPreviewSeek?(seekTime(newValue))
        }
        let commitValue: () -> Void = {
            onCommitSeek?(seekTime(binding.wrappedValue))
        }

        return HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(formatTime(binding.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)

            TrimTimeField(
                value: binding,
                accessibilityTitle: title,
                focusedField: $focusedField,
                fieldID: title,
                onCommit: commitValue
            )

            Text("分:秒")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Stepper(value: binding, in: 0...max(0, maxValue), step: 0.5, onEditingChanged: { editing in
                if !editing { commitValue() }
            }) {
                Text(title)
            }
            .labelsHidden()
            .controlSize(.small)

            Spacer(minLength: 0)

            Button("リセット") {
                binding.wrappedValue = 0
                commitValue()
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
    var onPreviewSeek: ((TimeInterval) -> Void)?
    var onCommitSeek: ((TimeInterval) -> Void)?

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
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let frac = max(0, min(value.location.x / w, 1 - endFrac - 0.02))
                                    startTrim = Double(frac) * duration
                                    onPreviewSeek?(segmentOffset + startTrim)
                                }
                                .onEnded { _ in
                                    onCommitSeek?(segmentOffset + startTrim)
                                }
                        )
                }

                // End handle
                if endTrim >= 0 {
                    TrimHandle(color: .accentColor)
                        .offset(x: activeEnd - 6)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let frac = max(0, min((w - value.location.x) / w, 1 - startFrac - 0.02))
                                    endTrim = Double(frac) * duration
                                    onPreviewSeek?(segmentOffset + duration - endTrim)
                                }
                                .onEnded { _ in
                                    onCommitSeek?(segmentOffset + duration - endTrim)
                                }
                        )
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

private final class TrimDurationFormatter: Formatter {
    override func string(for obj: Any?) -> String? {
        let seconds: TimeInterval
        if let number = obj as? NSNumber {
            seconds = number.doubleValue
        } else if let value = obj as? Double {
            seconds = value
        } else {
            return nil
        }
        return Self.string(from: seconds)
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        guard let seconds = Self.parse(string) else {
            errorDescription?.pointee = "分:秒形式で入力してください" as NSString
            return false
        }

        obj?.pointee = NSNumber(value: seconds)
        return true
    }

    static func string(from seconds: TimeInterval) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let total = tenths / 10
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let fraction = tenths % 10
        let secondText = fraction == 0 ? String(format: "%02d", s) : String(format: "%02d.%d", s, fraction)

        if h > 0 {
            return String(format: "%d:%02d:%@", h, m, secondText)
        }
        return "\(m):\(secondText)"
    }

    static func parse(_ string: String) -> TimeInterval? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: "時間", with: ":")
            .replacingOccurrences(of: "分", with: ":")
            .replacingOccurrences(of: "秒", with: "")

        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 {
            return Double(String(parts[0]))
        }
        if parts.count == 2,
           let minutes = Double(String(parts[0])),
           let seconds = Double(String(parts[1])) {
            return minutes * 60 + seconds
        }
        if parts.count == 3,
           let hours = Double(String(parts[0])),
           let minutes = Double(String(parts[1])),
           let seconds = Double(String(parts[2])) {
            return hours * 3600 + minutes * 60 + seconds
        }
        return nil
    }
}

/// Editable m:ss time field backed by a string buffer.
///
/// Typed input is applied live (the slider, output total and preview react
/// without pressing Return), while changes coming from the slider/stepper/reset
/// are reflected straight back into the field.
private struct TrimTimeField: View {
    @Binding var value: TimeInterval
    let accessibilityTitle: String
    @FocusState.Binding var focusedField: String?
    let fieldID: String
    let onCommit: () -> Void

    @State private var editText: String = ""

    private var isFocused: Bool {
        focusedField == fieldID
    }

    var body: some View {
        TextField("分:秒", text: $editText)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .frame(width: 68)
            .multilineTextAlignment(.trailing)
            .focused($focusedField, equals: fieldID)
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    // Load the editable text when editing starts.
                    editText = TrimDurationFormatter.string(from: value)
                } else {
                    commit()
                }
            }
            .onChange(of: editText) { _, newText in
                // Apply the typed value live so the slider, output total and
                // preview react immediately — no need to press Return. Partial or
                // invalid input (e.g. "6:") is simply not applied yet.
                guard isFocused else { return }
                if let parsed = TrimDurationFormatter.parse(newText), parsed != value {
                    value = parsed   // binding setter clamps to the valid range
                }
            }
            .onChange(of: value) { _, newValue in
                // Reflect changes coming from the slider / stepper / reset back
                // into the field. When the new value is the echo of our own
                // keystroke the text already represents it, so leave it alone and
                // avoid clobbering the cursor mid-typing.
                if isFocused, TrimDurationFormatter.parse(editText) == newValue { return }
                editText = TrimDurationFormatter.string(from: newValue)
            }
            .onAppear { editText = TrimDurationFormatter.string(from: value) }
            .accessibilityLabel("\(accessibilityTitle)カット時間")
    }

    private func commit() {
        if let parsed = TrimDurationFormatter.parse(editText) {
            value = parsed   // binding setter clamps to the valid range
        }
        editText = TrimDurationFormatter.string(from: value)
        onCommit()
    }
}
