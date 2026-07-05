import Foundation
import XCTest

final class FITDataPointTests: XCTestCase {
    func testResolvedGradePrefersNativeGrade() {
        let current = point(seconds: 1, distance: 0, altitude: 100, grade: 4.2)

        XCTAssertEqual(current.resolvedGrade(fallbackDataPoints: []), 4.2)
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
