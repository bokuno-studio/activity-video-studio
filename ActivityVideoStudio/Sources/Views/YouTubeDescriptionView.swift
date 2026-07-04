import SwiftUI
import AppKit

/// View showing the generated YouTube description with copy button.
struct YouTubeDescriptionView: View {
    @Binding var description: String
    let onGenerate: () -> Void
    let onAppear: () -> Void
    var isTextFocused: FocusState<Bool>.Binding
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YouTube 説明文")
                    .font(.headline)
                Spacer()

                Button {
                    onGenerate()
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
                .focused(isTextFocused)
        }
        .padding()
        .onAppear(perform: onAppear)
    }
}
