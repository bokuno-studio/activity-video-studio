import Foundation
import CoreLocation

/// Synchronizes FIT data points with video playback time.
/// Provides interpolated data for any given playback position.
final class TimeSync {

    /// A video segment with its time range in the FIT timeline.
    struct VideoSegment {
        let metadata: VideoMetadata
        let fitStartTime: Date?      // FIT time when this video starts
        let fitEndTime: Date?        // FIT time when this video ends
        let offsetSeconds: Double    // Manual sync offset (positive = FIT data delayed)
        let timeZoneCorrectionCandidate: TimeZoneCorrectionCandidate?

        var isSynced: Bool {
            fitStartTime != nil && fitEndTime != nil
        }
    }

    /// A timezone-sized offset that would improve overlap with the FIT activity window.
    struct TimeZoneCorrectionCandidate {
        let offsetSeconds: TimeInterval
        let correctedStartTime: Date
        let correctedEndTime: Date
        let overlapSeconds: TimeInterval
    }

    private let dataPoints: [FITDataPoint]
    private(set) var segments: [VideoSegment] = []
    private static let maximumInterpolationGap: TimeInterval = 5

    struct ExportSnapshot: @unchecked Sendable {
        private let dataPoints: [FITDataPoint]
        private let segments: [VideoSegment]

        fileprivate init(dataPoints: [FITDataPoint], segments: [VideoSegment]) {
            self.dataPoints = dataPoints
            self.segments = segments
        }

        func dataPoint(segmentIndex: Int, playbackTime: TimeInterval) -> FITDataPoint? {
            TimeSync.dataPoint(
                segmentIndex: segmentIndex,
                playbackTime: playbackTime,
                dataPoints: dataPoints,
                segments: segments
            )
        }

        func elapsedTime(segmentIndex: Int, playbackTime: TimeInterval) -> TimeInterval? {
            TimeSync.elapsedTime(
                segmentIndex: segmentIndex,
                playbackTime: playbackTime,
                dataPoints: dataPoints,
                segments: segments
            )
        }

        func interpolatedDataPoint(at date: Date) -> FITDataPoint? {
            TimeSync.interpolatedDataPoint(at: date, dataPoints: dataPoints)
        }
    }

    /// Activity start time from the first FIT data point.
    var activityStartTime: Date? { dataPoints.first?.timestamp }

    var firstSyncedSegment: VideoSegment? {
        segments.first { $0.isSynced }
    }

    init(dataPoints: [FITDataPoint]) {
        self.dataPoints = dataPoints.sorted { $0.timestamp < $1.timestamp }
    }

    @MainActor
    func makeExportCopy() -> ExportSnapshot {
        ExportSnapshot(dataPoints: dataPoints, segments: segments)
    }

    // MARK: - Setup

    /// Add a video and automatically sync it using its creationDate.
    func addVideo(_ metadata: VideoMetadata, offsetSeconds: Double = 0) {
        guard let creationDate = metadata.creationDate else {
            segments.append(VideoSegment(
                metadata: metadata,
                fitStartTime: nil,
                fitEndTime: nil,
                offsetSeconds: offsetSeconds,
                timeZoneCorrectionCandidate: nil
            ))
            return
        }

        let adjustedStart = creationDate.addingTimeInterval(offsetSeconds)
        let adjustedEnd = adjustedStart.addingTimeInterval(metadata.duration)
        let correctionCandidate = timeZoneCorrectionCandidate(
            for: metadata,
            currentStart: adjustedStart,
            currentEnd: adjustedEnd
        )

        let segment = VideoSegment(
            metadata: metadata,
            fitStartTime: adjustedStart,
            fitEndTime: adjustedEnd,
            offsetSeconds: offsetSeconds,
            timeZoneCorrectionCandidate: correctionCandidate
        )
        segments.append(segment)
    }

    /// Update the manual offset for a specific video segment.
    func updateOffset(segmentIndex: Int, offsetSeconds: Double) {
        guard segments.indices.contains(segmentIndex) else { return }
        let old = segments[segmentIndex]
        guard let creationDate = old.metadata.creationDate else {
            segments[segmentIndex] = VideoSegment(
                metadata: old.metadata,
                fitStartTime: nil,
                fitEndTime: nil,
                offsetSeconds: offsetSeconds,
                timeZoneCorrectionCandidate: nil
            )
            return
        }

        let adjustedStart = creationDate.addingTimeInterval(offsetSeconds)
        let adjustedEnd = adjustedStart.addingTimeInterval(old.metadata.duration)
        let correctionCandidate = timeZoneCorrectionCandidate(
            for: old.metadata,
            currentStart: adjustedStart,
            currentEnd: adjustedEnd
        )

        segments[segmentIndex] = VideoSegment(
            metadata: old.metadata,
            fitStartTime: adjustedStart,
            fitEndTime: adjustedEnd,
            offsetSeconds: offsetSeconds,
            timeZoneCorrectionCandidate: correctionCandidate
        )
    }

    // MARK: - Query

    /// Get interpolated FIT data for a video playback position.
    /// - Parameters:
    ///   - segmentIndex: Index of the video segment
    ///   - playbackTime: Playback position in seconds from video start
    /// - Returns: Interpolated data point, or nil if no data available
    func dataPoint(segmentIndex: Int, playbackTime: TimeInterval) -> FITDataPoint? {
        Self.dataPoint(
            segmentIndex: segmentIndex,
            playbackTime: playbackTime,
            dataPoints: dataPoints,
            segments: segments
        )
    }

    /// Get interpolated FIT data for an absolute FIT timestamp.
    func interpolatedDataPoint(at date: Date) -> FITDataPoint? {
        Self.interpolatedDataPoint(at: date, dataPoints: dataPoints)
    }

    private static func dataPoint(
        segmentIndex: Int,
        playbackTime: TimeInterval,
        dataPoints: [FITDataPoint],
        segments: [VideoSegment]
    ) -> FITDataPoint? {
        guard segments.indices.contains(segmentIndex) else { return nil }
        let segment = segments[segmentIndex]
        guard let fitStartTime = segment.fitStartTime else { return nil }

        let fitTime = fitStartTime.addingTimeInterval(playbackTime)
        return interpolatedDataPoint(at: fitTime, dataPoints: dataPoints)
    }

    private static func interpolatedDataPoint(at date: Date, dataPoints: [FITDataPoint]) -> FITDataPoint? {
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
        if range > Self.maximumInterpolationGap {
            return before
        }

        let fraction = (targetTime - beforeTime) / range
        var result = interpolate(before: before, after: after, fraction: fraction)

        // Compute grade from altitude if not present in FIT data
        if result.grade == nil, lo > 0 {
            result = computeGrade(result: result, index: lo, dataPoints: dataPoints)
        }

        return result
    }

    /// Elapsed time from activity start for a given playback position.
    func elapsedTime(segmentIndex: Int, playbackTime: TimeInterval) -> TimeInterval? {
        Self.elapsedTime(
            segmentIndex: segmentIndex,
            playbackTime: playbackTime,
            dataPoints: dataPoints,
            segments: segments
        )
    }

    private static func elapsedTime(
        segmentIndex: Int,
        playbackTime: TimeInterval,
        dataPoints: [FITDataPoint],
        segments: [VideoSegment]
    ) -> TimeInterval? {
        guard segments.indices.contains(segmentIndex),
              let start = dataPoints.first?.timestamp else { return nil }
        let segment = segments[segmentIndex]
        guard let fitStartTime = segment.fitStartTime else { return nil }
        let fitTime = fitStartTime.addingTimeInterval(playbackTime)
        return fitTime.timeIntervalSince(start)
    }

    // MARK: - Interpolation

    private static func interpolate(before: FITDataPoint, after: FITDataPoint, fraction: Double) -> FITDataPoint {
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
            grade: lerpOptional(before.grade, after.grade, fraction),
            temperature: fraction < 0.5 ? before.temperature : after.temperature,
            coreTemperature: lerpOptional(before.coreTemperature, after.coreTemperature, fraction),
            skinTemperature: lerpOptional(before.skinTemperature, after.skinTemperature, fraction)
        )
    }

    /// Compute grade from altitude difference over ~10 data points for smoothing.
    private static func computeGrade(result: FITDataPoint, index: Int, dataPoints: [FITDataPoint]) -> FITDataPoint {
        let lookback = min(index, 10)
        let prev = dataPoints[index - lookback]
        let curr = dataPoints[index]

        guard let altPrev = prev.altitude, let altCurr = curr.altitude,
              let distPrev = prev.distance, let distCurr = curr.distance else {
            return result
        }

        let distDelta = distCurr - distPrev
        guard distDelta > 1 else { return result }

        let grade = ((altCurr - altPrev) / distDelta) * 100.0

        return FITDataPoint(
            timestamp: result.timestamp,
            coordinate: result.coordinate,
            heartRate: result.heartRate,
            speed: result.speed,
            altitude: result.altitude,
            cadence: result.cadence,
            distance: result.distance,
            grade: grade,
            temperature: result.temperature,
            coreTemperature: result.coreTemperature,
            skinTemperature: result.skinTemperature
        )
    }

    private static func lerpOptional(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        guard let a = a, let b = b else { return a ?? b }
        return a + t * (b - a)
    }

    private func timeZoneCorrectionCandidate(
        for metadata: VideoMetadata,
        currentStart: Date,
        currentEnd: Date
    ) -> TimeZoneCorrectionCandidate? {
        guard !metadata.usesQuickTimeCreationDate,
              let fitStart = dataPoints.first?.timestamp,
              let fitEnd = dataPoints.last?.timestamp else {
            return nil
        }

        let videoDuration = currentEnd.timeIntervalSince(currentStart)
        let fitDuration = fitEnd.timeIntervalSince(fitStart)
        guard videoDuration > 0, fitDuration > 0 else { return nil }

        let currentOverlap = Self.overlapSeconds(
            currentStart,
            currentEnd,
            fitStart,
            fitEnd
        )
        let maximumPossibleOverlap = min(videoDuration, fitDuration)
        let minimumCandidateOverlap = max(1, maximumPossibleOverlap * 0.5)
        let minimumImprovement = max(1, min(60, maximumPossibleOverlap * 0.05))

        var bestCandidate: TimeZoneCorrectionCandidate?
        for offset in Self.timeZoneCorrectionOffsets(for: fitStart) {
            let correctedStart = currentStart.addingTimeInterval(offset)
            let correctedEnd = currentEnd.addingTimeInterval(offset)
            let overlap = Self.overlapSeconds(correctedStart, correctedEnd, fitStart, fitEnd)
            guard overlap >= minimumCandidateOverlap,
                  overlap >= currentOverlap + minimumImprovement else {
                continue
            }

            let candidate = TimeZoneCorrectionCandidate(
                offsetSeconds: offset,
                correctedStartTime: correctedStart,
                correctedEndTime: correctedEnd,
                overlapSeconds: overlap
            )

            guard let existing = bestCandidate else {
                bestCandidate = candidate
                continue
            }

            if overlap > existing.overlapSeconds ||
                (overlap == existing.overlapSeconds && abs(offset) < abs(existing.offsetSeconds)) {
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }

    private static func timeZoneCorrectionOffsets(for date: Date) -> [TimeInterval] {
        let offsets = Set(TimeZone.knownTimeZoneIdentifiers.compactMap { identifier -> Int? in
            TimeZone(identifier: identifier)?.secondsFromGMT(for: date)
        })

        return offsets
            .filter { $0 != 0 }
            .map { TimeInterval(-$0) }
            .sorted {
                if abs($0) == abs($1) { return $0 < $1 }
                return abs($0) < abs($1)
            }
    }

    private static func overlapSeconds(
        _ lhsStart: Date,
        _ lhsEnd: Date,
        _ rhsStart: Date,
        _ rhsEnd: Date
    ) -> TimeInterval {
        let start = max(lhsStart.timeIntervalSince1970, rhsStart.timeIntervalSince1970)
        let end = min(lhsEnd.timeIntervalSince1970, rhsEnd.timeIntervalSince1970)
        return max(0, end - start)
    }
}
