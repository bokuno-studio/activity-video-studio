import SwiftUI

/// Editor for adding/editing text overlays.
struct TextOverlayEditView: View {
    @Binding var overlays: [TextOverlay]
    let videoDuration: TimeInterval

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
                        duration: 5
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
                        .frame(minHeight: 60, maxHeight: 120)
                        .border(Color.secondary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

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
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("表示時間 (秒)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("5", value: $overlay.duration, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
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
                            Slider(value: $overlay.fontSize, in: 24...120, step: 2)
                        }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
    }
}
