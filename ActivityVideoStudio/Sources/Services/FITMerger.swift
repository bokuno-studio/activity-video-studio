import Foundation
import CoreLocation

struct FITRecordingGap: Equatable {
    let start: Date
    let end: Date
    var duration: TimeInterval { end.timeIntervalSince(start) }
    func contains(_ date: Date) -> Bool { date > start && date < end }
}

enum FITRecordingState: Equatable {
    case waitingForStart
    case recording
    case noRecording
}

/// Normalizes independently-recorded FIT activities into one chronological activity.
struct FITMerger {
    static let gapThreshold: TimeInterval = 5

    struct Source {
        let dataPoints: [FITDataPoint]
        let hrZoneConfig: FITParser.HRZoneConfig?
    }

    struct Result {
        let dataPoints: [FITDataPoint]
        let gaps: [FITRecordingGap]
        let hrZoneConfig: FITParser.HRZoneConfig?
        let chronologicalSourceIndices: [Int]
    }

    static func merge(_ sources: [Source]) -> Result {
        let ordered = sources.enumerated().filter { !$0.element.dataPoints.isEmpty }.sorted {
            let a = $0.element.dataPoints.map(\.timestamp).min()!
            let b = $1.element.dataPoints.map(\.timestamp).min()!
            return a == b ? $0.offset < $1.offset : a < b
        }
        var result: [FITDataPoint] = []
        var offset = 0.0
        var lastTimestamp: Date?
        var lastDistance: Double?
        for entry in ordered {
            let points = entry.element.dataPoints.sorted { $0.timestamp < $1.timestamp }
            for point in points where lastTimestamp == nil || point.timestamp > lastTimestamp! {
                let distance = point.distance.map { max($0 + offset, lastDistance ?? 0) }
                result.append(point.withDistance(distance))
                lastTimestamp = point.timestamp
                if let distance { lastDistance = distance }
            }
            offset = lastDistance ?? offset
        }
        return Result(dataPoints: result, gaps: gaps(in: result), hrZoneConfig: ordered.first?.element.hrZoneConfig,
                      chronologicalSourceIndices: ordered.map(\.offset))
    }

    static func gaps(in dataPoints: [FITDataPoint]) -> [FITRecordingGap] {
        zip(dataPoints, dataPoints.dropFirst()).compactMap {
            $1.timestamp.timeIntervalSince($0.timestamp) > gapThreshold ? FITRecordingGap(start: $0.timestamp, end: $1.timestamp) : nil
        }
    }

    /// Cumulative gain derived only from adjacent, recorded samples.
    static func cumulativeElevationGains(in dataPoints: [FITDataPoint]) -> [Double] {
        var gains: [Double] = []
        gains.reserveCapacity(dataPoints.count)
        var gain = 0.0
        var previous: FITDataPoint?
        for point in dataPoints {
            if let previous, point.timestamp.timeIntervalSince(previous.timestamp) <= gapThreshold,
               let oldAltitude = previous.altitude, let altitude = point.altitude, altitude > oldAltitude {
                gain += altitude - oldAltitude
            }
            gains.append(gain)
            previous = point
        }
        return gains
    }

    static func recordingState(at date: Date, firstTimestamp: Date?, gaps: [FITRecordingGap]) -> FITRecordingState {
        guard let firstTimestamp else { return .waitingForStart }
        if date < firstTimestamp { return .waitingForStart }
        return gaps.contains(where: { $0.contains(date) }) ? .noRecording : .recording
    }

    static func trackSegments(from dataPoints: [FITDataPoint]) -> [[CLLocationCoordinate2D]] {
        var segments: [[CLLocationCoordinate2D]] = []
        var segment: [CLLocationCoordinate2D] = []
        for (index, point) in dataPoints.enumerated() {
            if index > 0, point.timestamp.timeIntervalSince(dataPoints[index - 1].timestamp) > gapThreshold {
                if !segment.isEmpty { segments.append(segment) }; segment = []
            }
            if let coordinate = point.coordinate, CLLocationCoordinate2DIsValid(coordinate) { segment.append(coordinate) }
        }
        if !segment.isEmpty { segments.append(segment) }
        return segments
    }
}
