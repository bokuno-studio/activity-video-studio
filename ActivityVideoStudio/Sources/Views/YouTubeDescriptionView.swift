import SwiftUI
import AppKit

/// View showing the generated YouTube description with copy button.
struct YouTubeDescriptionView: View {
    let dataPoints: [FITDataPoint]
    let videoStartDate: Date?
    @State private var description: String = ""
    @State private var chapterInterval: Double = 1.0
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YouTube 説明文")
                    .font(.headline)
                Spacer()

                HStack(spacing: 4) {
                    Text("チャプター間隔:")
                        .font(.caption)
                    Picker("", selection: $chapterInterval) {
                        Text("0.5 km").tag(0.5)
                        Text("1 km").tag(1.0)
                        Text("2 km").tag(2.0)
                        Text("5 km").tag(5.0)
                    }
                    .frame(width: 80)
                    .onChange(of: chapterInterval) {
                        regenerate()
                    }
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

        let chapters: [(time: TimeInterval, label: String)]
        if let startDate = videoStartDate {
            chapters = YouTubeDescriptionGenerator.autoChapters(
                dataPoints: dataPoints,
                videoStartDate: startDate,
                intervalKm: chapterInterval
            )
        } else {
            chapters = []
        }

        description = YouTubeDescriptionGenerator.generate(
            summary: summary,
            chapters: chapters
        )
    }
}
