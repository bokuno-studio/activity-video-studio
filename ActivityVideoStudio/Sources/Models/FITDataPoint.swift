import Foundation
import CoreLocation

/// A single data point from a Garmin FIT record message.
struct FITDataPoint {
    private static let minimumPaceSpeedMetersPerSecond = 0.5

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

    func withDistance(_ distance: Double?) -> FITDataPoint {
        FITDataPoint(timestamp: timestamp, coordinate: coordinate, heartRate: heartRate, speed: speed,
                     altitude: altitude, cadence: cadence, distance: distance, grade: grade,
                     temperature: temperature, coreTemperature: coreTemperature, skinTemperature: skinTemperature)
    }

    /// Remove values that must not be displayed during a recording gap.
    func withoutLiveMetrics() -> FITDataPoint {
        FITDataPoint(timestamp: timestamp, coordinate: nil, heartRate: nil, speed: nil,
                     altitude: nil, cadence: nil, distance: nil, grade: nil,
                     temperature: nil, coreTemperature: nil, skinTemperature: nil)
    }

    /// Running cadence: Garmin stores single-foot strides, double for total spm
    var runningCadence: Int? {
        guard let cadence = cadence, cadence > 0 else { return nil }
        return Int(cadence) * 2
    }

    /// Pace in seconds per km, computed from speed
    var paceSecondsPerKm: Double? {
        guard let speed = speed, speed >= Self.minimumPaceSpeedMetersPerSecond else { return nil }
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

        guard let currentDistance = distance, currentDistance > 0 else { return nil }
        guard let anchorIndex = Self.lastIndex(in: dataPoints, atOrBeforeDistance: currentDistance),
              anchorIndex > 0 else {
            return nil
        }

        let lookback = min(anchorIndex, 10)
        let previous = dataPoints[anchorIndex - lookback]
        let anchor = dataPoints[anchorIndex]

        guard !Self.hasGap(from: anchorIndex - lookback, through: anchorIndex, in: dataPoints) else { return nil }

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

    private static func hasGap(from start: Int, through end: Int, in points: [FITDataPoint]) -> Bool {
        guard start >= 0, end < points.count, start < end else { return false }
        return (start + 1 ... end).contains { points[$0].timestamp.timeIntervalSince(points[$0 - 1].timestamp) > FITMerger.gapThreshold }
    }

    private static func lastIndex(in dataPoints: [FITDataPoint], atOrBeforeDistance target: Double) -> Int? {
        guard !dataPoints.isEmpty else { return nil }

        var lo = 0
        var hi = dataPoints.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if let distance = dataPoints[mid].distance, distance <= target {
                lo = mid
            } else {
                hi = mid - 1
            }
        }

        guard let distance = dataPoints[lo].distance, distance <= target else {
            return nil
        }
        return lo
    }

    func gradeFormatted(fallbackDataPoints dataPoints: [FITDataPoint]) -> String {
        guard let grade = resolvedGrade(fallbackDataPoints: dataPoints) else {
            return "--%"
        }

        let displayGrade = abs(grade) < 0.05 ? 0 : grade
        return String(format: "%+.1f%%", displayGrade)
    }
}
