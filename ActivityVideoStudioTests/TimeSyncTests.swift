import Foundation
import XCTest

final class TimeSyncTests: XCTestCase {
    func testInitializesWithSortedDataPoints() throws {
        let sync = TimeSync(dataPoints: [
            point(seconds: 4, speed: 3),
            point(seconds: 0, speed: 1),
            point(seconds: 2, speed: 2)
        ])

        XCTAssertEqual(sync.activityStartTime, date(seconds: 0))
        let interpolated = try XCTUnwrap(sync.interpolatedDataPoint(at: date(seconds: 1)))
        XCTAssertEqual(interpolated.speed ?? 0, 1.5, accuracy: 0.001)
    }

    func testNegativeSegmentIndexIsIgnored() {
        let sync = TimeSync(dataPoints: [point(seconds: 0, speed: 1)])
        sync.addVideo(VideoMetadata(
            url: URL(fileURLWithPath: "/tmp/video.mov"),
            creationDate: date(seconds: 0),
            duration: 10,
            naturalSize: nil
        ))

        XCTAssertNil(sync.dataPoint(segmentIndex: -1, playbackTime: 0))
        XCTAssertNil(sync.elapsedTime(segmentIndex: -1, playbackTime: 0))
        sync.updateOffset(segmentIndex: -1, offsetSeconds: 10)
        XCTAssertEqual(sync.segments.first?.offsetSeconds, 0)
    }

    @MainActor
    func testExportCopyIsIndependentOfLaterOffsetUpdates() throws {
        let sync = TimeSync(dataPoints: [
            point(seconds: 0, speed: 1),
            point(seconds: 4, speed: 5),
            point(seconds: 20, speed: 20)
        ])
        sync.addVideo(VideoMetadata(
            url: URL(fileURLWithPath: "/tmp/video.mov"),
            creationDate: date(seconds: 0),
            duration: 30,
            naturalSize: nil
        ))

        let snapshot = sync.makeExportCopy()
        sync.updateOffset(segmentIndex: 0, offsetSeconds: 20)

        let snapshotPoint = try XCTUnwrap(snapshot.dataPoint(segmentIndex: 0, playbackTime: 2))
        let livePoint = try XCTUnwrap(sync.dataPoint(segmentIndex: 0, playbackTime: 2))
        XCTAssertEqual(snapshotPoint.speed ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(livePoint.speed, 20)
        XCTAssertEqual(snapshot.elapsedTime(segmentIndex: 0, playbackTime: 2), 2)
        XCTAssertEqual(sync.elapsedTime(segmentIndex: 0, playbackTime: 2), 22)
    }

    func testLargeGapReturnsPreviousPointWithoutSmoothInterpolation() throws {
        let sync = TimeSync(dataPoints: [
            point(seconds: 0, speed: 1, distance: 0),
            point(seconds: 30, speed: 5, distance: 100)
        ])

        let pointInGap = try XCTUnwrap(sync.interpolatedDataPoint(at: date(seconds: 15)))
        XCTAssertEqual(pointInGap.timestamp, date(seconds: 0))
        XCTAssertEqual(pointInGap.speed, 1)
        XCTAssertEqual(pointInGap.distance, 0)
    }

    func testLowSpeedPaceUsesPlaceholderPath() {
        XCTAssertNil(point(seconds: 0, speed: 0.05).paceFormatted)
        XCTAssertEqual(point(seconds: 0, speed: 1).paceFormatted, "16'40\"")
    }

    private func point(
        seconds: TimeInterval,
        speed: Double?,
        distance: Double? = nil
    ) -> FITDataPoint {
        FITDataPoint(
            timestamp: date(seconds: seconds),
            coordinate: nil,
            heartRate: nil,
            speed: speed,
            altitude: nil,
            cadence: nil,
            distance: distance,
            grade: nil,
            temperature: nil,
            coreTemperature: nil,
            skinTemperature: nil
        )
    }

    private func date(seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
