import Foundation
import CoreLocation
import XCTest

final class FITDataPointTests: XCTestCase {
    func testResolvedGradePrefersNativeGrade() {
        let current = point(seconds: 1, distance: 0, altitude: 100, grade: 4.2)

        XCTAssertEqual(current.resolvedGrade(fallbackDataPoints: []), 4.2)
    }

    func testResolvedGradeRejectsOutOfRangeNativeGrade() {
        let current = point(seconds: 1, distance: 100, altitude: 110, grade: -120.9)

        XCTAssertNil(current.resolvedGrade(fallbackDataPoints: []))
        XCTAssertEqual(current.gradeFormatted(fallbackDataPoints: []), "--%")
    }

    func testResolvedGradeReturnsNilAtZeroDistanceWithoutFallback() {
        let dataPoints = (0..<50).map {
            point(seconds: TimeInterval($0), distance: 0, altitude: 100 + Double($0), grade: nil)
        }
        let current = point(seconds: 60, distance: 0, altitude: 150, grade: nil)

        XCTAssertNil(current.resolvedGrade(fallbackDataPoints: dataPoints))
        XCTAssertEqual(current.gradeFormatted(fallbackDataPoints: dataPoints), "--%")
    }

    func testResolvedGradeComputesFallbackFromDistanceAnchor() {
        let dataPoints = (0...20).map {
            point(seconds: TimeInterval($0), distance: Double($0 * 10), altitude: 100 + Double($0), grade: nil)
        }
        let current = dataPoints[15]

        XCTAssertEqual(current.resolvedGrade(fallbackDataPoints: dataPoints) ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(current.gradeFormatted(fallbackDataPoints: dataPoints), "+10.0%")
    }

    func testResolvedGradeSuppressesShortDistanceWindow() {
        let dataPoints = (0...10).map {
            point(seconds: TimeInterval($0), distance: Double($0) * 0.12, altitude: 100 - Double($0) * 0.12, grade: nil)
        }

        XCTAssertNil(dataPoints.last?.resolvedGrade(fallbackDataPoints: dataPoints))
        XCTAssertEqual(dataPoints.last?.gradeFormatted(fallbackDataPoints: dataPoints), "--%")
    }

    func testResolvedGradeExpandsWindowUntilTwentyMeters() {
        let dataPoints = (0...4).map {
            point(seconds: TimeInterval($0 * 5), distance: Double($0 * 5), altitude: 100 + Double($0) * 0.5, grade: nil)
        }

        XCTAssertEqual(dataPoints.last?.resolvedGrade(fallbackDataPoints: dataPoints) ?? 0, 10, accuracy: 0.001)
    }

    func testResolvedGradeUsesTimestampWhenLaterSamplesHaveTheSameDistance() {
        let dataPoints = [
            point(seconds: 0, distance: 0, altitude: 100, grade: nil),
            point(seconds: 5, distance: 10, altitude: 101, grade: nil),
            point(seconds: 10, distance: 20, altitude: 102, grade: nil),
            point(seconds: 15, distance: 30, altitude: 103, grade: nil),
            point(seconds: 20, distance: 30, altitude: 103, grade: nil)
        ]

        XCTAssertEqual(dataPoints[3].resolvedGrade(fallbackDataPoints: dataPoints) ?? 0, 10, accuracy: 0.001)
    }

    func testResolvedGradeSkipsIsolatedMissingAndNonMonotonicSamples() {
        let dataPoints = [
            point(seconds: 0, distance: 0, altitude: 100, grade: nil),
            point(seconds: 1, distance: 10, altitude: 101, grade: nil),
            point(seconds: 2, distance: 40, altitude: 104, grade: nil),
            point(seconds: 3, distance: nil, altitude: nil, grade: nil),
            point(seconds: 4, distance: 30, altitude: 103, grade: nil)
        ]

        XCTAssertEqual(dataPoints.last?.resolvedGrade(fallbackDataPoints: dataPoints) ?? 0, 10, accuracy: 0.001)
    }

    func testResolvedGradeCalculatesNormalOneHundredMeterClimb() {
        let dataPoints = (0...5).map {
            point(seconds: TimeInterval($0), distance: Double($0 * 20), altitude: 100 + Double($0 * 2), grade: nil)
        }

        XCTAssertEqual(dataPoints.last?.resolvedGrade(fallbackDataPoints: dataPoints) ?? 0, 10, accuracy: 0.001)
    }

    func testResolvedGradeDoesNotCrossRecordingGap() {
        let dataPoints = [
            point(seconds: 0, distance: 0, altitude: 100, grade: nil),
            point(seconds: 4, distance: 5, altitude: 100.5, grade: nil),
            point(seconds: 20, distance: 10, altitude: 101, grade: nil),
            point(seconds: 24, distance: 20, altitude: 102, grade: nil)
        ]

        XCTAssertNil(dataPoints[3].resolvedGrade(fallbackDataPoints: dataPoints))
    }

    func testWithoutLiveMetricsRemovesDistanceAndPositionData() {
        let original = FITDataPoint(
            timestamp: Date(timeIntervalSince1970: 1),
            coordinate: CLLocationCoordinate2D(latitude: 35, longitude: 138),
            heartRate: 150,
            speed: 3,
            altitude: 1_200,
            cadence: 80,
            distance: 2_500,
            grade: 8,
            temperature: 20,
            coreTemperature: 38,
            skinTemperature: 34
        )

        let sanitized = original.withoutLiveMetrics()

        XCTAssertNil(sanitized.coordinate)
        XCTAssertNil(sanitized.distance)
        XCTAssertNil(sanitized.heartRate)
        XCTAssertNil(sanitized.speed)
        XCTAssertNil(sanitized.altitude)
        XCTAssertNil(sanitized.cadence)
        XCTAssertNil(sanitized.grade)
    }

    private func point(
        seconds: TimeInterval,
        distance: Double?,
        altitude: Double?,
        grade: Double?
    ) -> FITDataPoint {
        FITDataPoint(
            timestamp: Date(timeIntervalSince1970: seconds),
            coordinate: nil,
            heartRate: nil,
            speed: nil,
            altitude: altitude,
            cadence: nil,
            distance: distance,
            grade: grade,
            temperature: nil,
            coreTemperature: nil,
            skinTemperature: nil
        )
    }
}
