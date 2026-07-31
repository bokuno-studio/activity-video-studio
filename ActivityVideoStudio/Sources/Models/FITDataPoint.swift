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

    func withGrade(_ grade: Double?) -> FITDataPoint {
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
        GradeResolver.resolve(for: self, fallbackDataPoints: dataPoints)
    }

    func gradeFormatted(fallbackDataPoints dataPoints: [FITDataPoint]) -> String {
        guard let grade = resolvedGrade(fallbackDataPoints: dataPoints) else {
            return "--%"
        }

        let displayGrade = abs(grade) < 0.05 ? 0 : grade
        return String(format: "%+.1f%%", displayGrade)
    }
}

/// Resolves a displayable grade from native FIT data or a bounded distance-based window.
enum GradeResolver {
    static let minimumWindowDistance = 20.0
    static let maximumWindowDistance = 100.0
    static let maximumWindowDuration: TimeInterval = 60
    static let maximumAbsoluteGrade = 60.0

    static func resolve(for current: FITDataPoint, fallbackDataPoints dataPoints: [FITDataPoint]) -> Double? {
        // A FIT grade field takes precedence, even when its value is rejected as implausible.
        if let nativeGrade = current.grade {
            return validated(nativeGrade)
        }

        guard let currentDistance = current.distance, currentDistance > 0,
              let currentAltitude = current.altitude,
              let anchorIndex = lastIndex(in: dataPoints, atOrBefore: current.timestamp) else {
            return nil
        }

        var candidateIndex = anchorIndex
        while candidateIndex >= 0 {
            let candidate = dataPoints[candidateIndex]

            // Missing measurements and isolated distance regressions are common around
            // GPS loss. They cannot form a window, but must not discard earlier data.
            if candidateIndex < anchorIndex,
               dataPoints[candidateIndex + 1].timestamp.timeIntervalSince(candidate.timestamp) > FITMerger.gapThreshold {
                return nil
            }

            let duration = current.timestamp.timeIntervalSince(candidate.timestamp)
            guard duration >= 0 else {
                candidateIndex -= 1
                continue
            }
            guard duration <= maximumWindowDuration else { return nil }

            guard let candidateDistance = candidate.distance else {
                candidateIndex -= 1
                continue
            }

            let distanceDelta = currentDistance - candidateDistance
            guard distanceDelta >= 0 else {
                candidateIndex -= 1
                continue
            }
            guard distanceDelta <= maximumWindowDistance else { return nil }

            if distanceDelta >= minimumWindowDistance {
                if let candidateAltitude = candidate.altitude {
                    return validated(((currentAltitude - candidateAltitude) / distanceDelta) * 100.0)
                }
            }

            candidateIndex -= 1
        }

        return nil
    }

    private static func validated(_ grade: Double) -> Double? {
        guard grade.isFinite, abs(grade) <= maximumAbsoluteGrade else { return nil }
        return grade
    }

    private static func lastIndex(in dataPoints: [FITDataPoint], atOrBefore timestamp: Date) -> Int? {
        guard !dataPoints.isEmpty else { return nil }

        var lo = 0
        var hi = dataPoints.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if dataPoints[mid].timestamp <= timestamp {
                lo = mid
            } else {
                hi = mid - 1
            }
        }

        return dataPoints[lo].timestamp <= timestamp ? lo : nil
    }
}
