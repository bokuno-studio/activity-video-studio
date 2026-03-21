import Foundation
import CoreLocation

/// A single data point from a Garmin FIT record message.
struct FITDataPoint {
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D?
    let heartRate: UInt8?          // bpm
    let speed: Double?             // m/s
    let altitude: Double?          // meters
    let cadence: UInt8?            // spm
    let distance: Double?          // meters (cumulative)
    let grade: Double?             // percent

    /// Pace in min/km, computed from speed
    var pace: Double? {
        guard let speed = speed, speed > 0 else { return nil }
        return 1000.0 / 60.0 / speed
    }
}
