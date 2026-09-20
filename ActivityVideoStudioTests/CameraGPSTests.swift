import XCTest
import CoreLocation

final class CameraGPSTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_785_889_805.72)
    private let coordinate = CLLocationCoordinate2D(latitude: 35, longitude: 139)

    func testGPS5KLVScalingUTCAndSampleTiming() throws {
        let points = GPMFParser.parse(payload(), playbackTime: 2, duration: 1)
        XCTAssertEqual(points.count, 2)
        let first = try XCTUnwrap(points.first)
        XCTAssertEqual(first.coordinate.latitude, 35, accuracy: 0.000001)
        XCTAssertEqual(first.coordinate.longitude, -139, accuracy: 0.000001)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(formatter.string(from: first.timestamp), "2026-07-25T00:30:05.720Z")
        XCTAssertEqual(points[1].playbackTime, 2.5)
        XCTAssertEqual(points[1].timestamp.timeIntervalSince(first.timestamp), 0.5)
    }

    func testGPS9RealMaterialLayoutAndUTCWithoutGPSU() throws {
        // Issue #129's actual first record, repeated at 10 Hz in a GPS9-only stream.
        let points = GPMFParser.parse(gps9Payload(), playbackTime: 0.28, duration: 1)
        XCTAssertEqual(points.count, 10)
        let first = try XCTUnwrap(points.first)
        XCTAssertEqual(first.coordinate.latitude, 35.3118938, accuracy: 0.0000001)
        XCTAssertEqual(first.coordinate.longitude, 138.7669106, accuracy: 0.0000001)
        XCTAssertEqual(first.timestamp, ISO8601DateFormatter().date(from: "2026-07-25T00:30:06Z"))
        XCTAssertEqual(points[9].timestamp.timeIntervalSince(first.timestamp), 0.9, accuracy: 0.000001)
        XCTAssertEqual(points[9].playbackTime, 1.18, accuracy: 0.000001)
        let creation = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-25T00:30:47Z"))
        let alignment = try XCTUnwrap(CameraGPSAlignment.calculate(videos: [video(creation, duration: 2)],
            samples: [points], activity: []))
        XCTAssertEqual(alignment.offsetSeconds, -41.28, accuracy: 0.000001)
    }

    func testGPS9TYPEControlsWidthsSignednessAndArrayExpansion() throws {
        // A 34-byte layout, with unsigned days and signed coordinates. DOP > Int16.max.
        let points = GPMFParser.parse(gps9Payload(type: "l[5]LlSL", wideFix: true, longitude: -1_387_669_106),
                                      playbackTime: 0, duration: 1)
        XCTAssertEqual(points.count, 10)
        XCTAssertEqual(try XCTUnwrap(points.first).coordinate.longitude, -138.7669106, accuracy: 0.0000001)
        XCTAssertEqual(points.first?.timestamp, ISO8601DateFormatter().date(from: "2026-07-25T00:30:06Z"))
        XCTAssertEqual(GPMFParser.parse(gps9Payload(type: "l[7]S[2]"), playbackTime: 0, duration: 1).count, 10)
    }

    func testGPS9FixFiltersIndividualRecordsWithoutCompressingPlaybackTime() throws {
        let points = GPMFParser.parse(gps9Payload(fixes: [0, 1, 2, 3, 4, 65535, 0, 1, 2, 3]),
                                      playbackTime: 2, duration: 1)
        XCTAssertEqual(points.count, 4)
        for (point, index) in zip(points, [2, 3, 8, 9]) {
            XCTAssertEqual(point.playbackTime, 2 + Double(index) / 10, accuracy: 0.000001)
            let utc = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-25T00:30:06Z"))
            XCTAssertEqual(point.timestamp.timeIntervalSince(utc), Double(index) / 10, accuracy: 0.000001)
        }
    }

    func testGPS9UTCUsesEachRecordAcrossMidnight() throws {
        let points = GPMFParser.parse(gps9Payload(days: 9702, seconds: 86_399_700), playbackTime: 0, duration: 2)
        XCTAssertEqual(points.count, 10)
        XCTAssertEqual(points[3].timestamp, ISO8601DateFormatter().date(from: "2026-07-26T00:00:00Z"))
        // UTC increments by 0.1s from the records, not the 0.2s playback spacing.
        XCTAssertEqual(points[9].timestamp.timeIntervalSince(points[0].timestamp), 0.9, accuracy: 0.000001)
        XCTAssertEqual(points[9].playbackTime, 1.8, accuracy: 0.000001)
    }

    func testGPS9MalformedMetadataAndTruncationAreSafe() {
        for type in ["", "lllllllS", "lllllllSSS", "lllllllSX", "l[0]SS", "l[99]SS", "l[7SS", "l[7]S[2]x", "l[7]S[2]\0x"] {
            XCTAssertTrue(GPMFParser.parse(gps9Payload(type: type), playbackTime: 0, duration: 1).isEmpty, type)
        }
        for bytes in [gps9Payload(type: nil), gps9Payload(type: "lllllllSS", wideFix: true),
                      gps9Payload(scale: 0), gps9Payload(scale: -1), gps9Payload(days: -1),
                      gps9Payload(longitude: 1_900_000_000)] {
            XCTAssertTrue(GPMFParser.parse(bytes, playbackTime: 0, duration: 1).isEmpty)
        }
        let bytes = gps9Payload()
        for count in 0..<bytes.count {
            XCTAssertTrue(GPMFParser.parse(Data(bytes.prefix(count)), playbackTime: 0, duration: 1).isEmpty)
        }
    }

    func testIndexedMP4GPS9Payload() throws {
        let points = try CameraGPSReader.read(data: movie(telemetry: gps9Payload()))
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.playbackTime, 2)
        XCTAssertEqual(try XCTUnwrap(points.first).coordinate.latitude, 35.3118938, accuracy: 0.0000001)
    }

    func testMissingInvalidAndTruncatedGPSAreSafe() {
        XCTAssertTrue(GPMFParser.parse(Data(), playbackTime: 0, duration: 1).isEmpty)
        XCTAssertTrue(GPMFParser.parse(payload(fix: 0), playbackTime: 0, duration: 1).isEmpty)
        XCTAssertTrue(GPMFParser.parse(payload(scale: 0), playbackTime: 0, duration: 1).isEmpty)
        for count in 0..<payload().count {
            XCTAssertTrue(GPMFParser.parse(Data(payload().prefix(count)), playbackTime: 0, duration: 1).isEmpty)
        }
    }

    func testMP4WithoutGPSTrackReturnsNoRecords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try box("moov", box("trak", box("mdia", box("minf", box("stbl", full("stsd", integers([1]) + box("avc1", Data()))))))).write(to: url)
        XCTAssertTrue(try CameraGPSReader.read(url: url).isEmpty)
    }

    func testIndexedMP4PayloadAndPresentationTime() throws {
        for wide in [false, true] {
            let points = try CameraGPSReader.read(data: movie(wide: wide))
            XCTAssertEqual(points.count, 1)
            XCTAssertEqual(points.first?.playbackTime, 2)
            XCTAssertEqual(points.first?.coordinate.latitude, 35)
        }
    }

    func testMalformedMovieFailsWithoutTrapping() {
        let bytes = movie()
        for count in 1..<bytes.count {
            _ = try? CameraGPSReader.read(data: Data(bytes.prefix(count)))
        }
    }

    func testOffsetUsesLocalPlaybackAndJoinedChapterTime() throws {
        let creation = date.addingTimeInterval(41.28)
        let videos = [video(creation, duration: 10), video(creation, duration: 10)]
        // GPS can be absent in chapter one and begin well into chapter two.
        let samples = [[], [sample(playback: 2, utc: 12)]]
        let result = try XCTUnwrap(CameraGPSAlignment.calculate(videos: videos, samples: samples,
                                                                activity: [point(10), point(14)]))
        XCTAssertEqual(result.offsetSeconds, -41.28, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(result.medianDistanceMeters), 0, accuracy: 0.001)
        XCTAssertFalse(result.needsConfirmation)
    }

    func testMultipleActivitiesAndChaptersUseOneCorrection() throws {
        let creation = date.addingTimeInterval(41.28)
        let videos = [video(creation, duration: 10), video(creation, duration: 10)]
        let sources = [[point(0), point(5)], [point(10), point(15)]]
        let merged = FITMerger.merge(sources.map { FITMerger.Source(dataPoints: $0, hrZoneConfig: nil) }).dataPoints
        let result = try XCTUnwrap(CameraGPSAlignment.calculate(videos: videos,
            samples: [[sample(playback: 0, utc: 0), sample(playback: 5, utc: 5)],
                      [sample(playback: 0, utc: 10), sample(playback: 5, utc: 15)]], activity: merged))
        XCTAssertEqual(result.offsetSeconds, -41.28, accuracy: 0.00001)
        XCTAssertEqual(result.comparedSamples, 4)
        let sync = TimeSync(dataPoints: merged)
        for index in videos.indices {
            sync.addVideo(video(creation.addingTimeInterval(Double(index) * 10), duration: 10), offsetSeconds: result.offsetSeconds)
        }
        XCTAssertEqual(sync.activityTime(segmentIndex: 1, playbackTime: 5), date.addingTimeInterval(15))
    }

    func testMismatchAndMissingOverlapRequireConfirmation() throws {
        let videos = [video(date, duration: 10)]
        let samples = [[sample(playback: 2, utc: 2)]]
        let far = try XCTUnwrap(CameraGPSAlignment.calculate(videos: videos, samples: samples,
            activity: [point(0, latitude: 36), point(5, latitude: 36)]))
        XCTAssertTrue(far.needsConfirmation)
        XCTAssertGreaterThan(try XCTUnwrap(far.medianDistanceMeters), 50)
        for records in [[point(20), point(25)], [point(-100), point(100)], []] {
            let result = try XCTUnwrap(CameraGPSAlignment.calculate(videos: videos, samples: samples, activity: records))
            XCTAssertNil(result.medianDistanceMeters)
            XCTAssertTrue(result.needsConfirmation)
        }
        XCTAssertNil(CameraGPSAlignment.calculate(videos: videos, samples: [[]], activity: []))
    }

    func testDistanceUsesInterpolationAndMedian() throws {
        let samples = [0.0, 5, 10].map { sample(playback: $0, utc: $0) }
        let result = try XCTUnwrap(CameraGPSAlignment.calculate(videos: [video(date, duration: 20)], samples: [samples],
            activity: [point(0), point(4, latitude: 34.999), point(6, latitude: 35.001), point(10, latitude: 36)]))
        XCTAssertEqual(result.comparedSamples, 3)
        XCTAssertEqual(try XCTUnwrap(result.medianDistanceMeters), 0, accuracy: 0.001)
    }

    private func video(_ creation: Date, duration: Double) -> VideoMetadata {
        VideoMetadata(url: URL(fileURLWithPath: "/tmp/video.mp4"), creationDate: creation, duration: duration, naturalSize: nil)
    }
    private func sample(playback: Double, utc: Double) -> CameraGPSSample {
        CameraGPSSample(playbackTime: playback, timestamp: date.addingTimeInterval(utc), coordinate: coordinate)
    }
    private func point(_ seconds: Double, latitude: Double = 35) -> FITDataPoint {
        FITDataPoint(timestamp: date.addingTimeInterval(seconds), coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 139),
                     heartRate: nil, speed: nil, altitude: nil, cadence: nil, distance: nil, grade: nil,
                     temperature: nil, coreTemperature: nil, skinTemperature: nil)
    }
    private func integers(_ values: [UInt32]) -> Data {
        Data(values.flatMap { value in [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] })
    }
    private func klv(_ key: String, type: UInt8, size: UInt8, count: UInt16, value: Data) -> Data {
        var result = Data(key.utf8) + Data([type, size, UInt8(count >> 8), UInt8(count & 255)]) + value
        while result.count % 4 != 0 { result.append(0) }
        return result
    }
    private func payload(fix: UInt32 = 3, scale: UInt32 = 10_000_000) -> Data {
        let scales = klv("SCAL", type: 108, size: 4, count: 5, value: integers([scale, scale, 1000, 1000, 1000]))
        let utc = klv("GPSU", type: 85, size: 16, count: 1, value: Data("260725003005.720".utf8))
        let fix = klv("GPSF", type: 76, size: 4, count: 1, value: integers([fix]))
        let values = [UInt32(350_000_000), UInt32(bitPattern: -1_390_000_000), 0, 0, 0]
        let gps = klv("GPS5", type: 108, size: 20, count: 2, value: integers(values + values))
        let stream = scales + utc + fix + gps
        let nested = klv("STRM", type: 0, size: 1, count: UInt16(stream.count), value: stream)
        return klv("DEVC", type: 0, size: 1, count: UInt16(nested.count), value: nested)
    }
    private func gps9Payload(type: String? = "lllllllSS", wideFix: Bool = false,
                             fixes: [UInt32] = Array(repeating: 2, count: 10),
                             longitude: Int32 = 1_387_669_106, scale: Int32 = 10_000_000,
                             days: Int32 = 9702, seconds: Int32 = 1_806_000) -> Data {
        var stream = Data()
        if let type {
            stream += klv("TYPE", type: 99, size: 1, count: UInt16(type.utf8.count), value: Data(type.utf8))
        }
        stream += klv("SCAL", type: 108, size: 4, count: 9,
            value: integers([scale, scale, 1000, 1000, 100, 1, 1000, 100, 1].map { UInt32(bitPattern: $0) }))
        var records = Data()
        for (index, fix) in fixes.enumerated() {
            let millis = seconds + Int32(index * 100)
            records += integers([353_118_938, longitude, 255_295, 477, 47,
                                 days + millis / 86_400_000, millis % 86_400_000].map { UInt32(bitPattern: $0) })
            records += wideFix ? Data([0xEA, 0x60]) : Data([0x02, 0x53])
            records += wideFix ? integers([fix]) : Data([UInt8(fix >> 8), UInt8(fix & 255)])
        }
        stream += klv("GPS9", type: 63, size: wideFix ? 34 : 32, count: UInt16(fixes.count), value: records)
        let nested = klv("STRM", type: 0, size: 1, count: UInt16(stream.count), value: stream)
        return klv("DEVC", type: 0, size: 1, count: UInt16(nested.count), value: nested)
    }
    private func box(_ key: String, _ bytes: Data) -> Data { integers([UInt32(bytes.count + 8)]) + Data(key.utf8) + bytes }
    private func full(_ key: String, _ bytes: Data) -> Data { box(key, integers([0]) + bytes) }
    private func movie(wide: Bool = false, telemetry: Data? = nil) -> Data {
        let bytes = telemetry ?? payload()
        let mdat = box("mdat", bytes)
        let stsd = full("stsd", integers([1]) + box("gpmd", Data(repeating: 0, count: 8)))
        let stts = full("stts", integers([1, 1, 1000]))
        let stsc = full("stsc", integers([1, 1, 1, 1]))
        let stsz = full("stsz", integers([0, 1, UInt32(bytes.count)]))
        let stco = full(wide ? "co64" : "stco", integers(wide ? [1, 0, 8] : [1, 8]))
        let stbl = box("stbl", stsd + stts + stsc + stsz + stco)
        let mdhd = full("mdhd", integers([0, 0, 1000, 1000]))
        // Empty two-second edit shifts telemetry onto the movie presentation timeline.
        let edts = box("edts", full("elst", integers([2, 2000, .max, 0x10000, 1000, 0, 0x10000])))
        return mdat + box("moov", full("mvhd", integers([0, 0, 1000, 3000])) + box("trak", edts + box("mdia", mdhd + box("minf", stbl))))
    }
}
