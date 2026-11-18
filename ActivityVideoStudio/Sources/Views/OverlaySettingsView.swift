import SwiftUI

/// Settings panel for overlay configuration.
struct OverlaySettingsView: View {
    @ObservedObject var settings: OverlaySettings
    let onImportTheme: () -> Void
    let onExportTheme: () -> Void

    init(
        settings: OverlaySettings,
        onImportTheme: @escaping () -> Void = {},
        onExportTheme: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.onImportTheme = onImportTheme
        self.onExportTheme = onExportTheme
    }

    @State private var showsZoneSettings = false

    var body: some View {
        Form {
            Section("デザイン") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(OverlayPreset.featured) { preset in
                        DesignThumbnailButton(
                            preset: preset,
                            isSelected: settings.selectedThemeID == preset.themeID
                        ) {
                            settings.selectTheme(id: preset.themeID)
                        }
                    }
                }
                .padding(.vertical, 2)

                HStack {
                    Menu {
                        ForEach(otherThemes) { theme in
                            Button {
                                settings.selectTheme(id: theme.id)
                            } label: {
                                if settings.selectedThemeID == theme.id {
                                    Label(themeLabel(for: theme), systemImage: "checkmark")
                                } else {
                                    Text(themeLabel(for: theme))
                                }
                            }
                        }
                        Divider()
                        Button("読み込み…") { onImportTheme() }
                        Button("選んでいるデザインを書き出す…") { onExportTheme() }
                    } label: {
                        Text(otherThemeMenuTitle)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                }
                .controlSize(.small)
            }

            Section("表示する項目") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("体").font(.caption).foregroundStyle(.secondary)
                    ChipFlowLayout(spacing: 6) {
                        MetricChip(title: "経過時間", isOn: $settings.showTime)
                        MetricChip(title: "ペース", isOn: $settings.showPace)
                        MetricChip(title: "心拍", isOn: $settings.showHeartRate)
                        MetricChip(title: "ケイデンス", isOn: $settings.showCadence)
                        MetricChip(title: "深部体温", isOn: $settings.showCoreTemp)
                    }
                    Text("コース").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ChipFlowLayout(spacing: 6) {
                        MetricChip(title: "距離", isOn: $settings.showDistance)
                        MetricChip(title: "地図", isOn: $settings.showMiniMap)
                        MetricChip(title: "標高グラフ", isOn: $settings.showElevationProfile)
                        MetricChip(title: "標高", isOn: $settings.showAltitude)
                        MetricChip(title: "勾配", isOn: $settings.showGrade)
                        MetricChip(title: "獲得標高", isOn: $settings.showElevationGain)
                    }
                }
                .padding(.vertical, 2)

                LabeledContent(opacityTitle) {
                    Slider(value: $settings.overlayOpacity, in: 0.3...1.0, step: 0.05)
                        .accessibilityLabel(opacityTitle)
                        .accessibilityValue(String(format: "%.0f%%", settings.overlayOpacity * 100))
                    Text(String(format: "%.0f%%", settings.overlayOpacity * 100))
                        .frame(width: 40)
                        .monospacedDigit()
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showsZoneSettings) {
                    zoneStepper("Z1 上限", value: zoneBinding(\.z1Max))
                    zoneStepper("Z2 上限", value: zoneBinding(\.z2Max))
                    zoneStepper("Z3 上限", value: zoneBinding(\.z3Max))
                    zoneStepper("Z4 上限", value: zoneBinding(\.z4Max))
                } label: {
                    HStack {
                        Text("心拍ゾーンの境目")
                        Spacer()
                        Text("\(settings.z1Max) / \(settings.z2Max) / \(settings.z3Max) / \(settings.z4Max)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                if let zoneValidationMessage {
                    Label(zoneValidationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("心拍ゾーン設定エラー: \(zoneValidationMessage)")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Themes not shown as thumbnails: other built-in variations and imported ones.
    private var otherThemes: [OverlayTheme] {
        let featuredIDs = Set(OverlayPreset.featured.map(\.themeID))
        return settings.availableThemes.filter { !featuredIDs.contains($0.id) }
    }

    private var otherThemeMenuTitle: String {
        if let selected = otherThemes.first(where: { $0.id == settings.selectedThemeID }) {
            return "ほかのデザイン：\(themeLabel(for: selected))"
        }
        return "ほかのデザイン・読み込み…"
    }

    private var opacityTitle: String {
        settings.selectedRenderStyle.layout == .classic ? "透明度" : "背景の濃さ"
    }

    private var selectedThemeBinding: Binding<String> {
        Binding(
            get: { settings.selectedThemeID },
            set: { settings.selectTheme(id: $0) }
        )
    }

    private func themeLabel(for theme: OverlayTheme) -> String {
        theme.isBuiltIn ? theme.displayName : "\(theme.displayName)（ユーザー）"
    }

    private func zoneStepper(_ title: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: 60...230, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue) bpm")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(title) bpm")
        .accessibilityValue("\(value.wrappedValue)")
    }

    private func zoneBinding(_ keyPath: ReferenceWritableKeyPath<OverlaySettings, UInt8>) -> Binding<Int> {
        Binding(
            get: { Int(settings[keyPath: keyPath]) },
            set: { newValue in
                settings[keyPath: keyPath] = UInt8(min(max(newValue, 60), 230))
            }
        )
    }

    private var zoneValidationMessage: String? {
        guard settings.z1Max < settings.z2Max,
              settings.z2Max < settings.z3Max,
              settings.z3Max < settings.z4Max else {
            return "Z1 < Z2 < Z3 < Z4 になるように設定してください"
        }
        return nil
    }
}

/// One of the four featured designs, shown as a small schematic picture.
private struct DesignThumbnailButton: View {
    let preset: OverlayPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                DesignThumbnail(preset: preset)
                    .aspectRatio(16 / 9, contentMode: .fit)
                Text(preset.title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("デザイン \(preset.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Schematic picture of where each design puts its panels.
private struct DesignThumbnail: View {
    let preset: OverlayPreset

    private let panel = Color(red: 12 / 255, green: 14 / 255, blue: 18 / 255).opacity(0.85)
    private let accent = Color(red: 1.0, green: 0.416, blue: 0.239)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [Color(red: 0.55, green: 0.62, blue: 0.68), Color(red: 0.32, green: 0.34, blue: 0.33)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                switch preset {
                case .broadcast:
                    RoundedRectangle(cornerRadius: 2).fill(panel)
                        .frame(width: w * 0.58, height: h * 0.16)
                        .offset(x: w * 0.04, y: h * 0.80)
                    RoundedRectangle(cornerRadius: 2).fill(panel)
                        .frame(width: w * 0.34, height: h * 0.34)
                        .offset(x: w * 0.62, y: h * 0.62)
                    Capsule().fill(accent)
                        .frame(width: w * 0.08, height: 2)
                        .offset(x: w * 0.65, y: h * 0.70)
                case .minimal:
                    bar(w * 0.18, h * 0.07).offset(x: w * 0.05, y: h * 0.07)
                    bar(w * 0.26, h * 0.13).offset(x: w * 0.05, y: h * 0.70)
                    bar(w * 0.16, h * 0.05).offset(x: w * 0.05, y: h * 0.87)
                    bar(w * 0.20, h * 0.10).offset(x: w * 0.75, y: h * 0.76)
                    Capsule().fill(accent)
                        .frame(width: w * 0.20, height: 2)
                        .offset(x: w * 0.75, y: h * 0.90)
                case .cards:
                    RoundedRectangle(cornerRadius: 3).fill(panel)
                        .frame(width: w * 0.28, height: h * 0.36)
                        .offset(x: w * 0.03, y: h * 0.60)
                    RoundedRectangle(cornerRadius: 3).fill(panel)
                        .frame(width: w * 0.24, height: h * 0.52)
                        .offset(x: w * 0.73, y: h * 0.44)
                    Capsule().fill(accent)
                        .frame(width: w * 0.10, height: 2)
                        .offset(x: w * 0.75, y: h * 0.50)
                default:
                    Rectangle().fill(Color.black.opacity(0.45))
                        .frame(width: w * 0.30, height: h * 0.42)
                        .offset(x: w * 0.03, y: h * 0.05)
                    Rectangle().fill(Color.black.opacity(0.45))
                        .frame(width: w * 0.22, height: h * 0.28)
                        .offset(x: w * 0.75, y: h * 0.03)
                    Rectangle().fill(Color.black.opacity(0.45))
                        .frame(width: w * 0.24, height: h * 0.50)
                        .offset(x: w * 0.73, y: h * 0.40)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(Color.white)
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.4), radius: 1)
    }
}

/// A toggle shown as a pill button.
private struct MetricChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(
                    Capsule().fill(isOn ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "表示" : "非表示")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Wraps its children onto new lines when the row is full.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
