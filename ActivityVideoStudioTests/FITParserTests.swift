import Foundation
import CoreLocation
import XCTest

final class FITParserTests: XCTestCase {
    func testParsesMultipleRecordMessages() throws {
        let result = try FITParser().parse(data: FITTestFixtures.multiRecordFIT())

        XCTAssertEqual(result.dataPoints.count, 2)
        XCTAssertEqual(result.dataPoints.map(\.timestamp), [
            garminDate(seconds: 1_000),
            garminDate(seconds: 1_001)
        ])
        XCTAssertEqual(result.dataPoints[0].speed ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.dataPoints[1].speed ?? 0, 2.5, accuracy: 0.001)
    }

    func testBigEndianRecordAppliesFITScaling() throws {
        let result = try FITParser().parse(data: FITTestFixtures.bigEndianScaledRecordFIT())

        let point = try XCTUnwrap(result.dataPoints.first)
        XCTAssertEqual(point.timestamp, garminDate(seconds: 1_234))
        let coordinate = try XCTUnwrap(point.coordinate)
        XCTAssertTrue(CLLocationCoordinate2DIsValid(coordinate))
        XCTAssertEqual(coordinate.latitude, 90, accuracy: 0.000001)
        XCTAssertEqual(coordinate.longitude, -45, accuracy: 0.000001)
        XCTAssertEqual(point.heartRate, 154)
        XCTAssertEqual(point.speed ?? 0, 1.234, accuracy: 0.001)
        XCTAssertEqual(point.altitude ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(point.cadence, 88)
        XCTAssertEqual(point.distance ?? 0, 123.45, accuracy: 0.001)
        XCTAssertEqual(point.grade ?? 0, -3.21, accuracy: 0.001)
        XCTAssertEqual(point.temperature, -5)
    }

    func testDeveloperTemperaturesUseFieldDescriptions() throws {
        let result = try FITParser().parse(data: FITTestFixtures.developerTemperatureFIT())

        XCTAssertEqual(result.dataPoints.count, 1)
        let point = try XCTUnwrap(result.dataPoints.first)
        XCTAssertEqual(point.coreTemperature ?? 0, 38.1, accuracy: 0.001)
        XCTAssertEqual(point.skinTemperature ?? 0, 32.5, accuracy: 0.001)
    }

    func testLegacyDeveloperTemperaturesFallbackWithoutFieldDescriptions() throws {
        let result = try FITParser().parse(data: FITTestFixtures.legacyDeveloperTemperatureFIT())

        XCTAssertEqual(result.dataPoints.count, 1)
        let point = try XCTUnwrap(result.dataPoints.first)
        XCTAssertEqual(point.coreTemperature ?? 0, 37.9, accuracy: 0.001)
        XCTAssertEqual(point.skinTemperature ?? 0, 31.8, accuracy: 0.001)
    }

    func testLegacyDeveloperTemperatureFallbackIsBlockedByFieldDescription() throws {
        let result = try FITParser().parse(data: FITTestFixtures.legacyFallbackBlockedByFieldDescriptionFIT())

        XCTAssertEqual(result.dataPoints.count, 1)
        let point = try XCTUnwrap(result.dataPoints.first)
        XCTAssertNil(point.coreTemperature)
        XCTAssertNil(point.skinTemperature)
    }

    func testCompressedTimestampUsesTimestampFromAnyMessage() throws {
        let result = try FITParser().parse(data: FITTestFixtures.compressedTimestampFIT())

        let point = try XCTUnwrap(result.dataPoints.first)
        XCTAssertEqual(point.heartRate, 150)
        XCTAssertEqual(point.timestamp, garminDate(seconds: 1_005))
    }

    func testCompressedTimestampWrapsPastLowFiveBitBoundary() throws {
        let result = try FITParser().parse(data: FITTestFixtures.compressedTimestampWrapFIT())

        let point = try XCTUnwrap(result.dataPoints.first)
        XCTAssertEqual(point.heartRate, 151)
        XCTAssertEqual(point.timestamp, garminDate(seconds: 1_026))
    }

    func testDataSliceWithNonZeroStartIndexParses() throws {
        var prefixed = Data([0xAA, 0xBB, 0xCC])
        prefixed.append(FITTestFixtures.simpleFIT())

        let slice: Data = prefixed[3..<prefixed.count]
        let result = try FITParser().parse(data: slice)

        XCTAssertEqual(result.dataPoints.count, 1)
        XCTAssertEqual(result.dataPoints.first?.speed, 1.0)
    }

    func testTruncatedFITThrowsUnexpectedEndOfData() {
        var data = FITTestFixtures.simpleFIT()
        data.removeLast()

        XCTAssertThrowsError(try FITParser().parse(data: data)) { error in
            guard case FITParser.ParseError.unexpectedEndOfData = error else {
                return XCTFail("Expected unexpectedEndOfData, got \(error)")
            }
        }
    }

    func testCRCFailureThrowsMismatch() {
        var data = FITTestFixtures.simpleFIT()
        data[14] ^= 0x01

        XCTAssertThrowsError(try FITParser().parse(data: data)) { error in
            guard case FITParser.ParseError.crcMismatch = error else {
                return XCTFail("Expected crcMismatch, got \(error)")
            }
        }
    }

    func testZeroPlaceholderCRCsAreAccepted() throws {
        let result = try FITParser().parse(data: FITTestFixtures.simpleFITWithZeroCRCs())

        XCTAssertEqual(result.dataPoints.count, 1)
        XCTAssertEqual(result.dataPoints.first?.speed, 1.0)
    }

    func testZipStoredEntryPrefersActivityFIT() throws {
        let result = try FITParser().parse(data: FITTestFixtures.zipWithPreferredActivityFIT())

        XCTAssertEqual(result.dataPoints.count, 1)
        let point = try XCTUnwrap(result.dataPoints.first)
        XCTAssertEqual(point.timestamp, garminDate(seconds: 2_000))
        XCTAssertEqual(point.speed ?? 0, 3.0, accuracy: 0.001)
    }

    func testEmptyCompressedZipEntryThrowsInsteadOfCrashing() {
        let zip = FITTestFixtures.zipWithEmptyDeflateFITEntry()

        XCTAssertThrowsError(try FITParser().parse(data: zip)) { error in
            guard case FITParser.ParseError.zipDecompressionFailed("broken.fit") = error else {
                return XCTFail("Expected zipDecompressionFailed, got \(error)")
            }
        }
    }

    private func garminDate(seconds: UInt32) -> Date {
        var components = DateComponents()
        components.year = 1989
        components.month = 12
        components.day = 31
        components.timeZone = TimeZone(identifier: "UTC")
        let epoch = Calendar(identifier: .gregorian).date(from: components)!
        return epoch.addingTimeInterval(TimeInterval(seconds))
    }
}
