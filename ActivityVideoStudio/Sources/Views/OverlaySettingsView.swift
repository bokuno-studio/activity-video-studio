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

    var body: some View {
        Form {
            Section("表示項目") {
                Toggle("経過時間", isOn: $settings.showTime)
                Toggle("累計距離", isOn: $settings.showDistance)
                Toggle("心拍数", isOn: $settings.showHeartRate)
                Toggle("ペース", isOn: $settings.showPace)
                Toggle("標高", isOn: $settings.showAltitude)
                Toggle("傾斜", isOn: $settings.showGrade)
                Toggle("ケイデンス", isOn: $settings.showCadence)
                Toggle("累積獲得標高", isOn: $settings.showElevationGain)
                Toggle("深部体温 (CORE)", isOn: $settings.showCoreTemp)
            }

            Section("ウィジェット") {
                Toggle("ミニマップ", isOn: $settings.showMiniMap)
                Toggle("標高プロファイル", isOn: $settings.showElevationProfile)
            }

            Section("外観") {
                Picker("テーマ", selection: selectedThemeBinding) {
                    ForEach(settings.availableThemes) { theme in
                        Text(themeLabel(for: theme)).tag(theme.id)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Button {
                        onImportTheme()
                    } label: {
                        Label("読み込み", systemImage: "tray.and.arrow.down")
                    }
                    .help(".avstheme を読み込み")

                    Button {
                        onExportTheme()
                    } label: {
                        Label("書き出し", systemImage: "square.and.arrow.up")
                    }
                    .help("選択中テーマを .avstheme として保存")
                }
                .controlSize(.small)

                LabeledContent("透明度") {
                    Slider(value: $settings.overlayOpacity, in: 0.3...1.0, step: 0.05)
                        .accessibilityLabel("透明度")
                        .accessibilityValue(String(format: "%.0f%%", settings.overlayOpacity * 100))
                    Text(String(format: "%.0f%%", settings.overlayOpacity * 100))
                        .frame(width: 40)
                        .monospacedDigit()
                }
            }

            Section("心拍ゾーン (bpm)") {
                zoneStepper("Z1 上限", value: zoneBinding(\.z1Max))
                zoneStepper("Z2 上限", value: zoneBinding(\.z2Max))
                zoneStepper("Z3 上限", value: zoneBinding(\.z3Max))
                zoneStepper("Z4 上限", value: zoneBinding(\.z4Max))

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
