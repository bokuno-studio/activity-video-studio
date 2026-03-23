import SwiftUI

/// Shows a preview of the current frame with overlay applied.
struct ExportPreviewView: View {
    let previewImage: CGImage?
    let onGenerate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("エクスポートプレビュー")
                .font(.headline)

            if let image = previewImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 3)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay {
                        Text("プレビューを生成してください")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }

            Button(action: onGenerate) {
                Label("現在のフレームでプレビュー生成", systemImage: "eye")
            }
            .buttonStyle(.bordered)

            Text("実際のエクスポート時のオーバーレイ表示を確認できます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
