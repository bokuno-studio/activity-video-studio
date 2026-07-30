import XCTest

final class ElevationProfileTests: XCTestCase {
    func testSplitsSegmentsAndPreservesGapWidth() throws {
        let profile = try XCTUnwrap(makeProfile([
            point(0, distance: 0, altitude: 100), point(2, distance: 2, altitude: 110),
            point(20, distance: 3, altitude: 120), point(22, distance: 5, altitude: 130)
        ]))

        XCTAssertEqual(profile.segments.map(\.count), [2, 2])
        XCTAssertEqual(profile.segments[1][0].timeRatio - profile.segments[0][1].timeRatio, 18.0 / 22.0, accuracy: 0.001)
    }

    func testUsesTimeRatherThanDistanceForHorizontalPosition() throws {
        let profile = try XCTUnwrap(makeProfile([
            point(0, distance: 0, altitude: 100), point(2, distance: 10, altitude: 110),
            point(4, distance: 100, altitude: 120)
        ]))

        XCTAssertEqual(profile.segments[0][1].timeRatio, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(profile.segments[0][1].timeRatio, 0.1)
    }

    func testTimeRatioInGapFallsBetweenAdjacentSegments() throws {
        let profile = try XCTUnwrap(makeProfile([
            point(0, distance: 0, altitude: 100), point(2, distance: 2, altitude: 110),
            point(20, distance: 3, altitude: 120), point(22, distance: 5, altitude: 130)
        ]))
        let ratioInGap = try XCTUnwrap(profile.timeRatio(at: Date(timeIntervalSince1970: 10)))

        XCTAssertGreaterThan(ratioInGap, profile.segments[0][1].timeRatio)
        XCTAssertLessThan(ratioInGap, profile.segments[1][0].timeRatio)
    }

    func testContinuousDataCreatesOneSegment() throws {
        let profile = try XCTUnwrap(makeProfile([
            point(0, distance: 0, altitude: 100), point(2, distance: 1, altitude: 110), point(4, distance: 2, altitude: 120)
        ]))
        XCTAssertEqual(profile.segments.count, 1)
    }

    func testDownsamplingPreservesSegments() throws {
        let profile = try XCTUnwrap(makeProfile([
            point(0, distance: 0, altitude: 100), point(1, distance: 1, altitude: 110), point(2, distance: 2, altitude: 120),
            point(20, distance: 3, altitude: 130), point(21, distance: 4, altitude: 140), point(22, distance: 5, altitude: 150)
        ]))
        let downsampled = profile.downsampled(maxSamples: 2)
        XCTAssertEqual(downsampled.segments.count, 2)
        XCTAssertTrue(downsampled.segments.allSatisfy { !$0.isEmpty })
    }

    func testTimeRatioClampsOutsideActivity() throws {
        let profile = try XCTUnwrap(makeProfile([point(10, distance: 0, altitude: 100), point(20, distance: 1, altitude: 110)]))
        XCTAssertEqual(profile.timeRatio(at: Date(timeIntervalSince1970: 0)), 0)
        XCTAssertEqual(profile.timeRatio(at: Date(timeIntervalSince1970: 30)), 1)
    }

    private func makeProfile(_ points: [FITDataPoint]) -> ElevationProfile? { ElevationProfile.make(dataPoints: points) }

    private func point(_ seconds: TimeInterval, distance: Double, altitude: Double) -> FITDataPoint {
        FITDataPoint(timestamp: Date(timeIntervalSince1970: seconds), coordinate: nil, heartRate: nil, speed: nil, altitude: altitude, cadence: nil, distance: distance, grade: nil, temperature: nil, coreTemperature: nil, skinTemperature: nil)
    }
}
