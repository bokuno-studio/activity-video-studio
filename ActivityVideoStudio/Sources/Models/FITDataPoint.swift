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

    func resolvedGrade(fallbackDataPoints dataPoints: [FITDataPoint]) -> Double? {
        if let grade, grade.isFinite {
            return grade
        }

        guard let currentDistance = distance else { return nil }
        guard let anchorIndex = dataPoints.lastIndex(where: { point in
            guard let pointDistance = point.distance else { return false }
            return pointDistance <= currentDistance
        }), anchorIndex > 0 else {
            return nil
        }

        let lookback = min(anchorIndex, 10)
        let previous = dataPoints[anchorIndex - lookback]
        let anchor = dataPoints[anchorIndex]

        guard let previousAltitude = previous.altitude,
              let previousDistance = previous.distance,
              let currentAltitude = altitude ?? anchor.altitude else {
            return nil
        }

        let distanceDelta = currentDistance - previousDistance
        guard distanceDelta > 1 else { return nil }

        let computedGrade = ((currentAltitude - previousAltitude) / distanceDelta) * 100.0
        return computedGrade.isFinite ? computedGrade : nil
    }

    func gradeFormatted(fallbackDataPoints dataPoints: [FITDataPoint]) -> String {
        guard let grade = resolvedGrade(fallbackDataPoints: dataPoints) else {
            return "--%"
        }

        let displayGrade = abs(grade) < 0.05 ? 0 : grade
        return String(format: "%+.1f%%", displayGrade)
    }
}
