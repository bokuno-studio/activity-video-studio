import SwiftUI
import AppKit

/// View showing the generated YouTube description with copy button.
struct YouTubeDescriptionView: View {
    let dataPoints: [FITDataPoint]
    let videoStartDate: Date?
    let chapterMarkers: [ChapterMarker]
    let trimmedTime: (TimeInterval) -> TimeInterval
    @State private var description: String = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YouTube 説明文")
                    .font(.headline)
                Spacer()

                Button {
                    regenerate()
                } label: {
                    Label("生成", systemImage: "arrow.clockwise")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(description, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "コピー済み" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }

            TextEditor(text: $description)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 300)
        }
        .padding()
        .onAppear { regenerate() }
    }

    private func regenerate() {
        guard let summary = YouTubeDescriptionGenerator.summarize(dataPoints: dataPoints) else {
            description = "FIT データがありません"
            return
        }

        // Use chapter markers instead of auto-generated distance chapters
        let chapters = chapterMarkers.map { marker in
            (time: trimmedTime(marker.time), label: marker.label.isEmpty ? "チャプター" : marker.label)
        }

        description = YouTubeDescriptionGenerator.generate(
            summary: summary,
            chapters: chapters
        )
    }
}
