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
}
