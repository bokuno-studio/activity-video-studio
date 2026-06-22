import Foundation

/// Configuration for which overlay elements to display.
final class OverlaySettings: ObservableObject {
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

    /// Immutable export workers should not share the live SwiftUI settings object.
    func snapshot() -> OverlaySettings {
        let copy = OverlaySettings()
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
}
