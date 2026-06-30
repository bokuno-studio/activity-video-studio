import Foundation

/// Built-in visual styles for the burned-in activity overlay.
enum OverlayPreset: String, CaseIterable, Codable, Identifiable {
    case defaultPreset = "default"
    case compact
    case highContrast
    case lowerThird
    case mapLeft

    var id: String { rawValue }
    var themeID: String { "builtin.\(rawValue)" }

    var title: String {
        switch self {
        case .defaultPreset: return "デフォルト"
        case .compact: return "コンパクト"
        case .highContrast: return "高コントラスト"
        case .lowerThird: return "ローワーサード"
        case .mapLeft: return "マップ左"
        }
    }

    init?(themeID: String) {
        guard themeID.hasPrefix("builtin.") else { return nil }
        self.init(rawValue: String(themeID.dropFirst("builtin.".count)))
    }
}

/// Portable overlay theme file. Encoded as `.avstheme` JSON.
struct OverlayTheme: Codable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: String
    var displayName: String
    var style: OverlayPresetRenderStyle
    var isBuiltIn: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case displayName = "name"
        case style
    }

    init(
        schemaVersion: Int = OverlayTheme.currentSchemaVersion,
        id: String,
        displayName: String,
        style: OverlayPresetRenderStyle,
        isBuiltIn: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.style = style
        self.isBuiltIn = isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        style = try container.decode(OverlayPresetRenderStyle.self, forKey: .style)
        isBuiltIn = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(style, forKey: .style)
    }

    var fileBaseName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalized = id.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let base = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return base.isEmpty ? "overlay-theme" : base
    }

    static var builtInThemes: [OverlayTheme] {
        OverlayPreset.allCases.map { preset in
            OverlayTheme(
                id: preset.themeID,
                displayName: preset.title,
                style: preset.renderStyle,
                isBuiltIn: true
            )
        }
    }
}

/// Configuration for which overlay elements to display.
final class OverlaySettings: ObservableObject {
    @Published var overlayPreset: OverlayPreset = .defaultPreset {
        didSet {
            let themeID = overlayPreset.themeID
            if selectedThemeID != themeID {
                selectedThemeID = themeID
            }
        }
    }
    @Published var selectedThemeID: String = OverlayPreset.defaultPreset.themeID {
        didSet {
            if let preset = OverlayPreset(themeID: selectedThemeID),
               overlayPreset != preset {
                overlayPreset = preset
            }
        }
    }
    @Published var userThemes: [OverlayTheme] = []
    @Published var showTime = true
    @Published var showDistance = true
    @Published var showHeartRate = true
    @Published var showPace = true
    @Published var showGrade = true
    @Published var showAltitude = true
    @Published var showCadence = true
    @Published var showElevationGain = true
    @Published var showCoreTemp = true
    @Published var showMiniMap = true
    @Published var showElevationProfile = true
    @Published var overlayOpacity: Double = 0.7

    /// Heart rate zone thresholds
    @Published var z1Max: UInt8 = 120
    @Published var z2Max: UInt8 = 140
    @Published var z3Max: UInt8 = 155
    @Published var z4Max: UInt8 = 170

    /// Count of enabled metric items (excluding map and elevation profile).
    var enabledMetricCount: Int {
        [showTime, showDistance, showHeartRate, showPace, showGrade, showAltitude, showCadence]
            .filter { $0 }.count
    }

    var availableThemes: [OverlayTheme] {
        OverlayTheme.builtInThemes + userThemes
    }

    var builtInThemes: [OverlayTheme] {
        OverlayTheme.builtInThemes
    }

    var selectedTheme: OverlayTheme {
        theme(withID: selectedThemeID) ?? OverlayTheme.builtInThemes[0]
    }

    var selectedRenderStyle: OverlayPresetRenderStyle {
        selectedTheme.style
    }

    func theme(withID id: String) -> OverlayTheme? {
        availableThemes.first { $0.id == id }
    }

    func selectTheme(id: String) {
        guard theme(withID: id) != nil else {
            selectedThemeID = OverlayPreset.defaultPreset.themeID
            return
        }
        selectedThemeID = id
    }

    func installUserTheme(_ theme: OverlayTheme) {
        let importedTheme = OverlayTheme(
            schemaVersion: theme.schemaVersion,
            id: normalizedUserThemeID(theme.id),
            displayName: theme.displayName,
            style: theme.style,
            isBuiltIn: false
        )

        if let index = userThemes.firstIndex(where: { $0.id == importedTheme.id }) {
            userThemes[index] = importedTheme
        } else {
            userThemes.append(importedTheme)
        }

        selectedThemeID = importedTheme.id
    }

    func replaceUserThemes(_ themes: [OverlayTheme]) {
        userThemes = themes.map {
            OverlayTheme(
                schemaVersion: $0.schemaVersion,
                id: normalizedUserThemeID($0.id),
                displayName: $0.displayName,
                style: $0.style,
                isBuiltIn: false
            )
        }
    }

    /// Immutable export workers should not share the live SwiftUI settings object.
    func snapshot() -> OverlaySettings {
        let copy = OverlaySettings()
        copy.overlayPreset = overlayPreset
        copy.userThemes = userThemes
        copy.selectedThemeID = selectedThemeID
        copy.showTime = showTime
        copy.showDistance = showDistance
        copy.showHeartRate = showHeartRate
        copy.showPace = showPace
        copy.showGrade = showGrade
        copy.showAltitude = showAltitude
        copy.showCadence = showCadence
        copy.showElevationGain = showElevationGain
        copy.showCoreTemp = showCoreTemp
        copy.showMiniMap = showMiniMap
        copy.showElevationProfile = showElevationProfile
        copy.overlayOpacity = overlayOpacity
        copy.z1Max = z1Max
        copy.z2Max = z2Max
        copy.z3Max = z3Max
        copy.z4Max = z4Max
        return copy
    }

    private func normalizedUserThemeID(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "user.theme" : trimmed
        if candidate.hasPrefix("builtin.") {
            return "user.\(String(candidate.dropFirst("builtin.".count)))"
        }
        return candidate
    }
}
