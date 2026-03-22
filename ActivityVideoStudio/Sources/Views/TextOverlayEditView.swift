import SwiftUI

/// Editor for adding/editing text overlays.
struct TextOverlayEditView: View {
    @Binding var overlays: [TextOverlay]
    let videoDuration: TimeInterval

    @State private var selectedId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    selectedId = overlay.id
                } label: {
                    Image(systemName: "plus")
                }
            }

            if overlays.isEmpty {
                Text("テキストオーバーレイはありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach($overlays) { $overlay in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("テキスト", text: $overlay.text)
                            .textFieldStyle(.roundedBorder)

                        Button(role: .destructive) {
                            overlays.removeAll { $0.id == overlay.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Text("開始:")
                                .font(.caption)
                            TextField("", value: $overlay.startTime, format: .number)
                                .frame(width: 50)
                                .textFieldStyle(.roundedBorder)
                            Text("秒")
                                .font(.caption)
                        }

                        HStack(spacing: 4) {
                            Text("長さ:")
                                .font(.caption)
                            TextField("", value: $overlay.duration, format: .number)
                                .frame(width: 50)
                                .textFieldStyle(.roundedBorder)
                            Text("秒")
                                .font(.caption)
                        }

                        Picker("位置", selection: $overlay.position) {
                            ForEach(TextOverlay.Position.allCases, id: \.self) { pos in
                                Text(pos.rawValue).tag(pos)
                            }
                        }
                        .frame(width: 100)
                    }

                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Text("サイズ:")
                                .font(.caption)
                            Slider(value: $overlay.fontSize, in: 16...96, step: 2)
                                .frame(width: 100)
                            Text("\(Int(overlay.fontSize))pt")
                                .font(.caption)
                                .frame(width: 35)
                        }
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding()
    }
}
