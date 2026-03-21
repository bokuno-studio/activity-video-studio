import Foundation
import CoreLocation

/// Synchronizes FIT data points with video playback time.
/// Provides interpolated data for any given playback position.
final class TimeSync {

    /// A video segment with its time range in the FIT timeline.
    struct VideoSegment {
        let metadata: VideoMetadata
        let fitStartTime: Date      // FIT time when this video starts
        let fitEndTime: Date         // FIT time when this video ends
        let offsetSeconds: Double    // Manual sync offset (positive = FIT data delayed)
    }

    private let dataPoints: [FITDataPoint]
    private(set) var segments: [VideoSegment] = []

    /// Activity start time from the first FIT data point.
    var activityStartTime: Date? { dataPoints.first?.timestamp }

    init(dataPoints: [FITDataPoint]) {
        self.dataPoints = dataPoints
    }

    // MARK: - Setup

    /// Add a video and automatically sync it using its creationDate.
    func addVideo(_ metadata: VideoMetadata, offsetSeconds: Double = 0) {
        guard let creationDate = metadata.creationDate else { return }

        let adjustedStart = creationDate.addingTimeInterval(offsetSeconds)
        let adjustedEnd = adjustedStart.addingTimeInterval(metadata.duration)

        let segment = VideoSegment(
            metadata: metadata,
            fitStartTime: adjustedStart,
            fitEndTime: adjustedEnd,
            offsetSeconds: offsetSeconds
        )
        segments.append(segment)
        segments.sort { $0.fitStartTime < $1.fitStartTime }
    }

    /// Update the manual offset for a specific video segment.
    func updateOffset(segmentIndex: Int, offsetSeconds: Double) {
        guard segmentIndex < segments.count else { return }
        let old = segments[segmentIndex]
        guard let creationDate = old.metadata.creationDate else { return }

        let adjustedStart = creationDate.addingTimeInterval(offsetSeconds)
        let adjustedEnd = adjustedStart.addingTimeInterval(old.metadata.duration)

        segments[segmentIndex] = VideoSegment(
            metadata: old.metadata,
            fitStartTime: adjustedStart,
            fitEndTime: adjustedEnd,
            offsetSeconds: offsetSeconds
        )
    }

    // MARK: - Query

    /// Get interpolated FIT data for a video playback position.
    /// - Parameters:
    ///   - segmentIndex: Index of the video segment
    ///   - playbackTime: Playback position in seconds from video start
    /// - Returns: Interpolated data point, or nil if no data available
    func dataPoint(segmentIndex: Int, playbackTime: TimeInterval) -> FITDataPoint? {
        guard segmentIndex < segments.count else { return nil }
        let segment = segments[segmentIndex]

        let fitTime = segment.fitStartTime.addingTimeInterval(playbackTime)
        return interpolatedDataPoint(at: fitTime)
    }

    /// Get interpolated FIT data for an absolute FIT timestamp.
    func interpolatedDataPoint(at date: Date) -> FITDataPoint? {
        guard !dataPoints.isEmpty else { return nil }

        // Binary search for the closest data points
        let targetTime = date.timeIntervalSince1970
        var lo = 0
        var hi = dataPoints.count - 1

        // Before first data point
        if targetTime <= dataPoints[lo].timestamp.timeIntervalSince1970 {
            return dataPoints[lo]
        }
        // After last data point
        if targetTime >= dataPoints[hi].timestamp.timeIntervalSince1970 {
            return dataPoints[hi]
        }

        // Binary search
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if dataPoints[mid].timestamp.timeIntervalSince1970 <= targetTime {
                lo = mid
            } else {
                hi = mid
            }
        }

        let before = dataPoints[lo]
        let after = dataPoints[hi]

        let beforeTime = before.timestamp.timeIntervalSince1970
        let afterTime = after.timestamp.timeIntervalSince1970
        let range = afterTime - beforeTime
        guard range > 0 else { return before }

        let fraction = (targetTime - beforeTime) / range
        return interpolate(before: before, after: after, fraction: fraction)
    }

    /// Elapsed time from activity start for a given playback position.
    func elapsedTime(segmentIndex: Int, playbackTime: TimeInterval) -> TimeInterval? {
        guard segmentIndex < segments.count,
              let start = activityStartTime else { return nil }
        let segment = segments[segmentIndex]
        let fitTime = segment.fitStartTime.addingTimeInterval(playbackTime)
        return fitTime.timeIntervalSince(start)
    }

    // MARK: - Interpolation

    private func interpolate(before: FITDataPoint, after: FITDataPoint, fraction: Double) -> FITDataPoint {
        let timestamp = Date(
            timeIntervalSince1970: before.timestamp.timeIntervalSince1970
                + fraction * (after.timestamp.timeIntervalSince1970 - before.timestamp.timeIntervalSince1970)
        )

        let coordinate: CLLocationCoordinate2D?
        if let bc = before.coordinate, let ac = after.coordinate {
            coordinate = CLLocationCoordinate2D(
                latitude: bc.latitude + fraction * (ac.latitude - bc.latitude),
                longitude: bc.longitude + fraction * (ac.longitude - bc.longitude)
            )
        } else {
            coordinate = before.coordinate ?? after.coordinate
        }

        return FITDataPoint(
            timestamp: timestamp,
            coordinate: coordinate,
            heartRate: fraction < 0.5 ? before.heartRate : after.heartRate,
            speed: lerpOptional(before.speed, after.speed, fraction),
            altitude: lerpOptional(before.altitude, after.altitude, fraction),
            cadence: fraction < 0.5 ? before.cadence : after.cadence,
            distance: lerpOptional(before.distance, after.distance, fraction),
            grade: lerpOptional(before.grade, after.grade, fraction)
        )
    }

    private func lerpOptional(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        guard let a = a, let b = b else { return a ?? b }
        return a + t * (b - a)
    }
}
