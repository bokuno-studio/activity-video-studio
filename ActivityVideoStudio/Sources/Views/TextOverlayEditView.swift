import SwiftUI

/// Editor for adding/editing text overlays.
struct TextOverlayEditView: View {
    @Binding var overlays: [TextOverlay]
    let videoDuration: TimeInterval
    var isTextFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("テキストオーバーレイ")
                    .font(.headline)
                Spacer()
                Button {
                    let overlay = TextOverlay(
                        text: "タイトル",
                        startTime: 0,
                        duration: 15
                    )
                    overlays.append(overlay)
                } label: {
                    Label("追加", systemImage: "plus")
                }
            }

            if overlays.isEmpty {
                Text("「追加」ボタンでテキストを追加できます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }

            ForEach($overlays) { $overlay in
                VStack(alignment: .leading, spacing: 10) {
                    // Delete button
                    HStack {
                        Text("テキスト")
                            .font(.subheadline.bold())
                        Spacer()
                        Button(role: .destructive) {
                            overlays.removeAll { $0.id == overlay.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }

                    // Text input (multi-line)
                    TextEditor(text: $overlay.text)
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 150)
                        .border(Color.secondary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .focused(isTextFocused)

                    // Timing
                    VStack(alignment: .leading, spacing: 6) {
                        Text("タイミング")
                            .font(.subheadline.bold())

                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("開始 (秒)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("0", value: $overlay.startTime, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                    .focused(isTextFocused)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("表示時間 (秒)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("5", value: $overlay.duration, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                    .focused(isTextFocused)
                            }
                        }
                    }

                    // Position & Size
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("位置")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $overlay.position) {
                                ForEach(TextOverlay.Position.allCases, id: \.self) { pos in
                                    Text(pos.rawValue).tag(pos)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("サイズ: \(Int(overlay.fontSize))pt")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $overlay.fontSize, in: 24...300, step: 2)
                        }
                    }

                    // Auto-fit button
                    Button {
                        autoFitFontSize(overlay: &overlay)
                    } label: {
                        Label("画面幅に合わせる", systemImage: "arrow.left.and.right")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
    }

    /// Measure actual text width and compute font size to fill ~95% of screen width.
    private func autoFitFontSize(overlay: inout TextOverlay) {
        let lines = overlay.text.components(separatedBy: "\n")

        let targetWidth: CGFloat = 3840 * 0.95  // 95% of 4K width

        // Measure at a reference size, then scale
        let refSize: CGFloat = 100
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, refSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let maxLineWidth = lines
            .map { lineText -> CGFloat in
                let attrStr = NSAttributedString(string: lineText, attributes: attrs)
                let line = CTLineCreateWithAttributedString(attrStr)
                return CTLineGetBoundsWithOptions(line, []).width
            }
            .max() ?? 0

        guard maxLineWidth > 0 else { return }
        let fontSize = refSize * targetWidth / maxLineWidth
        overlay.fontSize = min(max(fontSize / 2, 24), 300)  // /2 because scale=2 for 4K
    }
}
