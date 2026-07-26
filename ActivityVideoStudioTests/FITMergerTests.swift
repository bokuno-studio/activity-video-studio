import XCTest
import CoreLocation

final class FITMergerTests: XCTestCase {
    private func point(_ seconds: TimeInterval, _ distance: Double, altitude: Double? = nil, coordinate: CLLocationCoordinate2D? = nil) -> FITDataPoint {
        FITDataPoint(timestamp: Date(timeIntervalSince1970: seconds), coordinate: coordinate, heartRate: nil, speed: nil,
                     altitude: altitude, cadence: nil, distance: distance, grade: nil, temperature: nil,
                     coreTemperature: nil, skinTemperature: nil)
    }

    func testMergeSortsRebasesAndFindsGap() {
        let later = FITMerger.Source(dataPoints: [point(20, 0), point(21, 10)], hrZoneConfig: nil)
        let earlier = FITMerger.Source(dataPoints: [point(0, 0), point(1, 100)], hrZoneConfig: nil)
        let result = FITMerger.merge([later, earlier])
        XCTAssertEqual(result.dataPoints.map(\.timestamp), [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 20), Date(timeIntervalSince1970: 21)])
        XCTAssertEqual(result.dataPoints.compactMap(\.distance), [0, 100, 100, 110])
        XCTAssertEqual(result.gaps, [FITRecordingGap(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 20))])
    }

    func testMergeDropsOverlappingTimestampFromLaterSource() {
        let a = FITMerger.Source(dataPoints: [point(0, 0), point(2, 20)], hrZoneConfig: nil)
        let b = FITMerger.Source(dataPoints: [point(2, 0), point(3, 10)], hrZoneConfig: nil)
        XCTAssertEqual(FITMerger.merge([a, b]).dataPoints.map(\.timestamp), [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 3)])
    }

    func testMergeIsIndependentOfInputOrderAndUsesEarliestHRZones() {
        let earlyZones = FITParser.HRZoneConfig(maxHeartRate: 180, thresholdHeartRate: 160)
        let lateZones = FITParser.HRZoneConfig(maxHeartRate: 200, thresholdHeartRate: 180)
        let early = FITMerger.Source(dataPoints: [point(0, 0), point(1, 10)], hrZoneConfig: earlyZones)
        let late = FITMerger.Source(dataPoints: [point(10, 0), point(11, 10)], hrZoneConfig: lateZones)
        let forward = FITMerger.merge([early, late])
        let reversed = FITMerger.merge([late, early])

        XCTAssertEqual(forward.dataPoints.map(\.timestamp), reversed.dataPoints.map(\.timestamp))
        XCTAssertEqual(forward.dataPoints.compactMap(\.distance), reversed.dataPoints.compactMap(\.distance))
        XCTAssertEqual(forward.hrZoneConfig?.maxHeartRate, 180)
        XCTAssertEqual(forward.hrZoneConfig?.thresholdHeartRate, 160)
    }

    func testSyntheticProductionTotalsAndGapDuration() {
        let first = FITMerger.Source(
            dataPoints: points(from: 0, through: 4_058, startingDistance: 0, endingDistance: 5_021.5),
            hrZoneConfig: nil
        )
        let second = FITMerger.Source(
            dataPoints: points(from: 6_104, through: 9_387, startingDistance: 1.3, endingDistance: 2_714.7),
            hrZoneConfig: nil
        )
        let result = FITMerger.merge([second, first])

        XCTAssertEqual(result.dataPoints.last?.distance ?? -1, 7_736.2, accuracy: 0.001)
        XCTAssertEqual(result.gaps.single?.duration ?? -1, 2_046, accuracy: 0.001)
    }

    private func points(
        from start: Int,
        through end: Int,
        startingDistance: Double,
        endingDistance: Double
    ) -> [FITDataPoint] {
        let duration = Double(end - start)
        return (start...end).map { second in
            let progress = Double(second - start) / duration
            return point(
                TimeInterval(second),
                startingDistance + (endingDistance - startingDistance) * progress
            )
        }
    }

    func testRecordingStateCoversWaitingGapAndAfterEnd() {
        let gaps = [FITRecordingGap(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20))]
        let first = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(FITMerger.recordingState(at: Date(timeIntervalSince1970: -1), firstTimestamp: first, gaps: gaps), .waitingForStart)
        XCTAssertEqual(FITMerger.recordingState(at: Date(timeIntervalSince1970: 15), firstTimestamp: first, gaps: gaps), .noRecording)
        XCTAssertEqual(FITMerger.recordingState(at: Date(timeIntervalSince1970: 25), firstTimestamp: first, gaps: gaps), .recording)
    }

    func testTrackSegmentsSplitAtGap() {
        let points = [
            point(0, 0, coordinate: CLLocationCoordinate2D(latitude: 35, longitude: 138)),
            point(1, 1, coordinate: CLLocationCoordinate2D(latitude: 35.1, longitude: 138.1)),
            point(10, 2, coordinate: CLLocationCoordinate2D(latitude: 35.2, longitude: 138.2)),
            point(11, 3, coordinate: CLLocationCoordinate2D(latitude: 35.3, longitude: 138.3))
        ]
        XCTAssertEqual(FITMerger.trackSegments(from: points).map(\.count), [2, 2])
    }

    func testElevationGainAndGradeExcludeAscendingGapBoundary() {
        let points = (0...10).map { index in point(TimeInterval(index), Double(index) * 10, altitude: Double(index)) } +
            [point(30, 110, altitude: 200)]
        XCTAssertEqual(FITMerger.cumulativeElevationGains(in: points).last, 10)
        XCTAssertNil(points.last?.resolvedGrade(fallbackDataPoints: points))
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
