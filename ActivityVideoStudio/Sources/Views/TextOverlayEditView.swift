import SwiftUI
import AppKit

/// Editor for adding/editing text overlays.
struct TextOverlayEditView: View {
    @Binding var overlays: [TextOverlay]
    @Binding var selectedOverlayID: TextOverlay.ID?
    let videoDuration: TimeInterval
    var isTextFocused: FocusState<Bool>.Binding
    private let fontFamilies: [String] = TextOverlayEditView.availableFontFamilies()

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
                    selectedOverlayID = overlay.id
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

            ForEach($overlays) { overlay in
                overlayEditor(overlay)
            }
        }
        .padding()
        .onAppear(perform: repairSelection)
        .onChange(of: overlays.map(\.id)) { _, _ in
            repairSelection()
        }
    }

    @ViewBuilder
    private func overlayEditor(_ overlay: Binding<TextOverlay>) -> some View {
        let id = overlay.wrappedValue.id
        let selected = selectedOverlayID == id

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("テキスト")
                    .font(.subheadline.bold())
                Spacer()
                Button(role: .destructive) {
                    overlays.removeAll { $0.id == id }
                    repairSelection()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }

            TextEditor(text: overlay.text)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 150)
                .border(Color.secondary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .focused(isTextFocused)

            timingControls(overlay)
            placementControls(overlay)
            fontControls(overlay)
            colorControls(overlay)
            outlineControls(overlay)
            shadowControls(overlay)
        }
        .padding(12)
        .background(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternaryLabelColor).opacity(0.18))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: selected ? 2 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedOverlayID = id
        }
    }

    @ViewBuilder
    private func timingControls(_ overlay: Binding<TextOverlay>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("タイミング")
                .font(.subheadline.bold())

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("開始 (秒)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("0", value: overlay.startTime, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused(isTextFocused)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("表示時間 (秒)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("5", value: overlay.duration, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused(isTextFocused)
                }
            }
        }
    }

    @ViewBuilder
    private func placementControls(_ overlay: Binding<TextOverlay>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("配置")
                .font(.subheadline.bold())

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("プリセット")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: positionBinding(overlay)) {
                        ForEach(TextOverlay.Position.allCases, id: \.self) { pos in
                            Text(pos.rawValue).tag(pos)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("X")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("0.50", value: relativeBinding(overlay, keyPath: \.relativeX), format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .focused(isTextFocused)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Y")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("0.50", value: relativeBinding(overlay, keyPath: \.relativeY), format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .focused(isTextFocused)
                }
            }

            VStack(spacing: 4) {
                Slider(value: relativeBinding(overlay, keyPath: \.relativeX), in: 0...1, step: 0.01)
                    .accessibilityLabel("X座標")
                Slider(value: relativeBinding(overlay, keyPath: \.relativeY), in: 0...1, step: 0.01)
                    .accessibilityLabel("Y座標")
            }
        }
    }

    @ViewBuilder
    private func fontControls(_ overlay: Binding<TextOverlay>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("フォント")
                .font(.subheadline.bold())

            Picker("ファミリー", selection: overlay.fontFamily) {
                ForEach(fontOptions(selected: overlay.wrappedValue.fontFamily), id: \.self) { family in
                    Text(family).tag(family)
                }
            }

            HStack(spacing: 12) {
                Picker("ウェイト", selection: overlay.fontWeight) {
                    ForEach(TextOverlay.FontWeight.allCases) { weight in
                        Text(weight.displayName).tag(weight)
                    }
                }
                .frame(width: 160)

                VStack(alignment: .leading, spacing: 2) {
                    Text("サイズ: \(Int(overlay.wrappedValue.fontSize))pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: overlay.fontSize, in: 24...300, step: 2)
                }
            }

            Button {
                var value = overlay.wrappedValue
                autoFitFontSize(overlay: &value)
                overlay.wrappedValue = value
            } label: {
                Label("画面幅に合わせる", systemImage: "arrow.left.and.right")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func colorControls(_ overlay: Binding<TextOverlay>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("色")
                .font(.subheadline.bold())

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    ColorPicker("文字", selection: colorBinding(overlay, keyPath: \.color), supportsOpacity: true)
                    ColorPicker("背景", selection: colorBinding(overlay, keyPath: \.backgroundColor), supportsOpacity: true)
                }
                GridRow {
                    ColorPicker("縁取り", selection: colorBinding(overlay, keyPath: \.strokeColor), supportsOpacity: true)
                    ColorPicker("影", selection: colorBinding(overlay, keyPath: \.shadowColor), supportsOpacity: true)
                }
            }
        }
    }

    @ViewBuilder
    private func outlineControls(_ overlay: Binding<TextOverlay>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("縁取り: \(Int(overlay.wrappedValue.strokeWidth))pt")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: overlay.strokeWidth, in: 0...24, step: 1)
        }
    }

    @ViewBuilder
    private func shadowControls(_ overlay: Binding<TextOverlay>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("影")
                .font(.subheadline.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text("ぼかし: \(Int(overlay.wrappedValue.shadowBlur))pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: overlay.shadowBlur, in: 0...40, step: 1)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Xオフセット")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("0", value: cgFloatBinding(overlay, keyPath: \.shadowOffsetX), format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                        .focused(isTextFocused)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Yオフセット")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("0", value: cgFloatBinding(overlay, keyPath: \.shadowOffsetY), format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                        .focused(isTextFocused)
                }
            }
        }
    }

    /// Measure actual text width and compute font size to fill ~95% of screen width.
    private func autoFitFontSize(overlay: inout TextOverlay) {
        let lines = overlay.text.components(separatedBy: "\n")

        let targetWidth: CGFloat = 3840 * 0.95  // 95% of 4K width

        // Measure at a reference size, then scale
        let refSize: CGFloat = 100
        let font = CTFontCreateWithName(fontName(for: overlay, size: refSize) as CFString, refSize, nil)
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

    private func positionBinding(_ overlay: Binding<TextOverlay>) -> Binding<TextOverlay.Position> {
        Binding(
            get: { overlay.wrappedValue.position },
            set: { newPosition in
                overlay.wrappedValue.applyPresetPosition(newPosition)
            }
        )
    }

    private func relativeBinding(_ overlay: Binding<TextOverlay>, keyPath: WritableKeyPath<TextOverlay, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(overlay.wrappedValue[keyPath: keyPath]) },
            set: { newValue in
                overlay.wrappedValue[keyPath: keyPath] = CGFloat(min(max(newValue, 0), 1))
            }
        )
    }

    private func cgFloatBinding(_ overlay: Binding<TextOverlay>, keyPath: WritableKeyPath<TextOverlay, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(overlay.wrappedValue[keyPath: keyPath]) },
            set: { newValue in
                overlay.wrappedValue[keyPath: keyPath] = CGFloat(newValue)
            }
        )
    }

    private func colorBinding(_ overlay: Binding<TextOverlay>, keyPath: WritableKeyPath<TextOverlay, CGColor>) -> Binding<Color> {
        Binding(
            get: {
                let nsColor = NSColor(cgColor: overlay.wrappedValue[keyPath: keyPath]) ?? .white
                return Color(nsColor: nsColor)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                overlay.wrappedValue[keyPath: keyPath] = (nsColor.usingColorSpace(.sRGB) ?? nsColor).cgColor
            }
        )
    }

    private func fontOptions(selected: String) -> [String] {
        if fontFamilies.contains(selected) {
            return fontFamilies
        }
        return [selected] + fontFamilies
    }

    private func fontName(for overlay: TextOverlay, size: CGFloat) -> String {
        let fallback = NSFont.systemFont(ofSize: size, weight: overlay.fontWeight.nsFontWeight)
        let nsFont = NSFontManager.shared.font(
            withFamily: overlay.fontFamily,
            traits: [],
            weight: overlay.fontWeight.nsFontManagerWeight,
            size: size
        ) ?? fallback

        return nsFont.fontName
    }

    private func repairSelection() {
        if let selectedOverlayID,
           overlays.contains(where: { $0.id == selectedOverlayID }) {
            return
        }
        selectedOverlayID = overlays.first?.id
    }

    private static func availableFontFamilies() -> [String] {
        let available = NSFontManager.shared.availableFontFamilies.sorted()
        let preferred = ["Helvetica", "Avenir Next", "Arial", "Georgia", "Menlo"]
        let pinned = preferred.filter { available.contains($0) }
        return pinned + available.filter { !pinned.contains($0) }
    }
}

private extension TextOverlay.FontWeight {
    var nsFontWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    var nsFontManagerWeight: Int {
        switch self {
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 10
        }
    }
}
