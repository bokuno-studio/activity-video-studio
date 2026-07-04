import Foundation
import XCTest

final class FITParserTests: XCTestCase {
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

    func testCompressedTimestampUsesTimestampFromAnyMessage() throws {
        let result = try FITParser().parse(data: FITTestFixtures.compressedTimestampFIT())

        let point = try XCTUnwrap(result.dataPoints.first)
        XCTAssertEqual(point.heartRate, 150)
        XCTAssertEqual(point.timestamp, garminDate(seconds: 1_005))
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
