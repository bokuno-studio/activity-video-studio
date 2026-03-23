import SwiftUI

/// Chapter marker list for YouTube chapters.
struct ChapterMarkerView: View {
    @Binding var markers: [ChapterMarker]
    let onSeek: (ChapterMarker) -> Void
    let onAdd: () -> Void
    var isTextFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("チャプターマーカー")
                    .font(.headline)
                Spacer()
                Button(action: onAdd) {
                    Label("現在位置にマーク", systemImage: "flag")
                }
                .keyboardShortcut("m", modifiers: [])
            }

            Text("再生中に M キーでマーカーを追加")
                .font(.caption)
                .foregroundStyle(.secondary)

            if markers.isEmpty {
                Text("マーカーはまだありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            }

            ForEach($markers) { $marker in
                HStack(spacing: 8) {
                    // Time badge
                    Button {
                        onSeek(marker)
                    } label: {
                        Text(formatTime(marker.time))
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.borderless)
                    .help("この位置にシーク")

                    // Label (Enter/Esc to unfocus)
                    TextField("ラベルを入力", text: $marker.label)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                        .focused(isTextFocused)
                        .onSubmit { isTextFocused.wrappedValue = false }

                    // Delete
                    Button(role: .destructive) {
                        markers.removeAll { $0.id == marker.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if !markers.isEmpty {
                Divider()

                // Preview of generated chapter list
                VStack(alignment: .leading, spacing: 4) {
                    Text("YouTube チャプター出力")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    let chapterText = generateChapterText()
                    Text(chapterText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(chapterText, forType: .string)
                    } label: {
                        Label("コピー", systemImage: "doc.on.doc")
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture {
            isTextFocused.wrappedValue = false
        }
    }

    private func generateChapterText() -> String {
        var lines: [String] = []
        if markers.isEmpty || (markers.first?.time ?? 1) > 0 {
            lines.append("0:00 スタート")
        }
        for marker in markers {
            let label = marker.label.isEmpty ? "チャプター" : marker.label
            lines.append("\(formatTime(marker.time)) \(label)")
        }
        return lines.joined(separator: "\n")
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
