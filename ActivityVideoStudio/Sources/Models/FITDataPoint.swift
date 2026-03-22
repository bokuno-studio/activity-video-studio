import Foundation
import CoreLocation

/// A single data point from a Garmin FIT record message.
struct FITDataPoint {
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D?
    let heartRate: UInt8?          // bpm
    let speed: Double?             // m/s
    let altitude: Double?          // meters
    let cadence: UInt8?            // Garmin stores single-foot strides/min for running
    let distance: Double?          // meters (cumulative)
    let grade: Double?             // percent
    let temperature: Int8?         // °C (ambient from device)
    let coreTemperature: Double?   // °C (CORE body temperature sensor, developer field)
    let skinTemperature: Double?   // °C (CORE skin temperature, developer field)

    /// Running cadence: Garmin stores single-foot strides, double for total spm
    var runningCadence: Int? {
        guard let cadence = cadence, cadence > 0 else { return nil }
        return Int(cadence) * 2
    }

    /// Pace in seconds per km, computed from speed
    var paceSecondsPerKm: Double? {
        guard let speed = speed, speed > 0 else { return nil }
        return 1000.0 / speed
    }

    /// Pace formatted as M'SS"/km
    var paceFormatted: String? {
        guard let totalSeconds = paceSecondsPerKm else { return nil }
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        return String(format: "%d'%02d\"", minutes, seconds)
    }
}
