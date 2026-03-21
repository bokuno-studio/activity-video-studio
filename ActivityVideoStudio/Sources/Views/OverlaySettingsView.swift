import SwiftUI

/// Settings panel for overlay configuration.
struct OverlaySettingsView: View {
    @ObservedObject var settings: OverlaySettings

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
            }

            Section("ウィジェット") {
                Toggle("ミニマップ", isOn: $settings.showMiniMap)
                Toggle("標高プロファイル", isOn: $settings.showElevationProfile)
            }

            Section("外観") {
                HStack {
                    Text("透明度")
                    Slider(value: $settings.overlayOpacity, in: 0.3...1.0, step: 0.05)
                    Text(String(format: "%.0f%%", settings.overlayOpacity * 100))
                        .frame(width: 40)
                        .monospacedDigit()
                }
            }

            Section("心拍ゾーン (bpm)") {
                HStack {
                    Text("Z1 上限")
                    Spacer()
                    TextField("", value: $settings.z1Max, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Z2 上限")
                    Spacer()
                    TextField("", value: $settings.z2Max, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Z3 上限")
                    Spacer()
                    TextField("", value: $settings.z3Max, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Z4 上限")
                    Spacer()
                    TextField("", value: $settings.z4Max, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 280)
    }
}
