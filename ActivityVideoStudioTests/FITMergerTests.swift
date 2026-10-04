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

    func testMergeRemovesUnderwaterGainAndPreservesClimb() {
        let climb = (0...10).map { point(Double($0), Double($0) * 10, altitude: Double($0)) }
        let points = climb + [point(11, 110, altitude: -80), point(12, 120, altitude: -90),
                              point(13, 130, altitude: -70), point(14, 140, altitude: 10),
                              point(15, 150, altitude: 11), point(16, 160, altitude: 12)]
        let result = FITMerger.merge([.init(dataPoints: points, hrZoneConfig: nil)])

        XCTAssertEqual(FITMerger.cumulativeElevationGains(in: result.dataPoints).last, 12)
        XCTAssertEqual(result.dataPoints[11...14].compactMap(\.altitude), [10, 10, 10, 10])
        XCTAssertEqual(result.dataPoints[13].resolvedGrade(fallbackDataPoints: result.dataPoints), 0)
        XCTAssertEqual(result.dataPoints.map(\.distance), points.map(\.distance))
    }

    func testNormalDescentIsUnchanged() {
        let points = (0...10).map { point(Double($0), Double($0), altitude: 30 - Double($0) * 3) }
        XCTAssertEqual(FITMerger.removingUnderwaterAltitudes(from: points).map(\.altitude), points.map(\.altitude))
    }

    func testUnderwaterTimeoutIsStrictlyAfter600Seconds() {
        let points = [point(0, 0, altitude: 10), point(1, 1, altitude: -80),
                      point(601, 2, altitude: -90), point(602, 3, altitude: -80),
                      point(603, 4, altitude: -79)]
        let corrected = FITMerger.removingUnderwaterAltitudes(from: points)
        XCTAssertEqual(corrected[1].altitude!, 10 - 90.0 / 602, accuracy: 0.000001)
        XCTAssertEqual(corrected[2].altitude!, 10 - 90.0 * 601 / 602, accuracy: 0.000001)
        XCTAssertEqual(corrected[3].altitude, -80)
        XCTAssertEqual(corrected[4].altitude, -79)
    }

    func testInterpolationUsesTimeAndSkipsMissingAltitudes() {
        let points = [point(0, 0, altitude: 10), point(1, 10), point(2, 20, altitude: -80),
                      point(3, 30), point(5, 50, altitude: -70), point(8, 80, altitude: 12)]
        let corrected = FITMerger.removingUnderwaterAltitudes(from: points)
        XCTAssertEqual(corrected.map(\.altitude), [10, nil, 10.5, nil, 11.25, 12])
        XCTAssertEqual(corrected.map(\.timestamp), points.map(\.timestamp))
    }

    func testUnrecoveredUnderwaterTailUsesLastNormalAltitude() {
        let points = [point(0, 0), point(1, 1, altitude: 10), point(2, 2, altitude: -80),
                      point(3, 3), point(4, 4, altitude: -90)]
        XCTAssertEqual(FITMerger.removingUnderwaterAltitudes(from: points).map(\.altitude), [nil, 10, 10, nil, 10])
        XCTAssertTrue(FITMerger.removingUnderwaterAltitudes(from: []).isEmpty)
        XCTAssertNil(FITMerger.removingUnderwaterAltitudes(from: [point(0, 0)])[0].altitude)
    }

    func testDetectionRespectsRateAndTimeBoundaries() {
        for points in [
            [point(0, 0, altitude: 10), point(1, 1, altitude: 5)],
            [point(0, 0, altitude: 10), point(0, 1, altitude: -80)],
            [point(0, 0, altitude: 10), point(6, 1, altitude: -80)]
        ] {
            XCTAssertEqual(FITMerger.removingUnderwaterAltitudes(from: points).map(\.altitude), points.map(\.altitude))
        }
        let points = [point(0, 0, altitude: 10), point(5, 1, altitude: -80)]
        XCTAssertEqual(FITMerger.removingUnderwaterAltitudes(from: points).compactMap(\.altitude), [10, 10])
    }

    func testRecoveryIncludesToleranceBoundaryAndAllowsAnotherEpisode() {
        let points = [point(0, 0, altitude: 10), point(1, 1, altitude: -80),
                      point(2, 2, altitude: 6.9), point(3, 3, altitude: 7),
                      point(4, 4, altitude: -80), point(5, 5, altitude: 7)]
        XCTAssertEqual(FITMerger.removingUnderwaterAltitudes(from: points).compactMap(\.altitude), [10, 9, 8, 7, 7, 7])
    }

    func testTimeoutCanStartNewEpisodeUsingPreviousUnderwaterSample() {
        let points = [point(0, 0, altitude: 10), point(1, 1, altitude: -80),
                      point(601, 2, altitude: -80), point(602, 3, altitude: -100),
                      point(603, 4, altitude: -80)]
        let corrected = FITMerger.removingUnderwaterAltitudes(from: points)
        XCTAssertEqual(corrected[3].altitude!, 10 - 90.0 * 602 / 603, accuracy: 0.000001)
        XCTAssertEqual(corrected[4].altitude, -80)
    }

    func testAltitudeReplacementPreservesOtherFields() {
        let original = FITDataPoint(timestamp: Date(timeIntervalSince1970: 1),
                                    coordinate: CLLocationCoordinate2D(latitude: 35, longitude: 138),
                                    heartRate: 140, speed: 2, altitude: -80, cadence: 80, distance: 10,
                                    grade: 4, temperature: 20, coreTemperature: 38, skinTemperature: 32)
        let corrected = FITMerger.removingUnderwaterAltitudes(from: [point(0, 0, altitude: 10), original])[1]
        XCTAssertEqual(corrected.altitude, 10)
        XCTAssertEqual(corrected.timestamp, original.timestamp)
        XCTAssertEqual(corrected.coordinate?.latitude, original.coordinate?.latitude)
        XCTAssertEqual(corrected.coordinate?.longitude, original.coordinate?.longitude)
        XCTAssertEqual(corrected.heartRate, original.heartRate)
        XCTAssertEqual(corrected.speed, original.speed)
        XCTAssertEqual(corrected.cadence, original.cadence)
        XCTAssertEqual(corrected.distance, original.distance)
        XCTAssertEqual(corrected.grade, original.grade)
        XCTAssertEqual(corrected.temperature, original.temperature)
        XCTAssertEqual(corrected.coreTemperature, original.coreTemperature)
        XCTAssertEqual(corrected.skinTemperature, original.skinTemperature)
        XCTAssertNil(original.withAltitude(nil).altitude)
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
