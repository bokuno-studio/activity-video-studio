import Foundation
import CoreLocation

struct CameraGPSSample {
    let playbackTime: TimeInterval
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
}

/// GPS5 subset of GPMF. Unknown keys are skipped; scope, padding and big-endian
/// values follow https://github.com/gopro/gpmf-parser. No GPS9 inference is made.
enum GPMFParser {
    private struct Entry {
        let key: String
        let type: UInt8
        let size: Int
        let count: Int
        let value: Data
    }

    static func parse(_ data: Data, playbackTime: Double, duration: Double) -> [CameraGPSSample] {
        guard playbackTime.isFinite, duration.isFinite, duration > 0 else { return [] }
        return parseScope(data, playbackTime: playbackTime, duration: duration, depth: 0)
    }

    private static func parseScope(_ data: Data, playbackTime: Double, duration: Double, depth: Int) -> [CameraGPSSample] {
        guard depth < 16 else { return [] }
        var entries: [Entry] = []
        var cursor = 0
        while cursor + 8 <= data.count {
            let size = Int(data[cursor + 5])
            let count = Int(data.uint(cursor + 6, 2))
            let length = size * count
            let padded = (length + 3) & ~3
            guard cursor + 8 + padded <= data.count else { return [] }
            entries.append(Entry(key: String(decoding: data[cursor..<cursor + 4], as: UTF8.self),
                                 type: data[cursor + 4], size: size, count: count,
                                 value: data.subdata(in: cursor + 8..<cursor + 8 + length)))
            cursor += 8 + padded
        }
        var result = entries.filter { $0.type == 0 }.flatMap {
            parseScope($0.value, playbackTime: playbackTime, duration: duration, depth: depth + 1)
        }
        guard let gps = entries.first(where: { $0.key == "GPS5" && $0.type == 108 && $0.size == 20 }),
              gps.count > 0,
              let utc = entries.first(where: { $0.key == "GPSU" && $0.type == 85 }),
              let timestamp = utcDate(utc.value),
              let scale = entries.first(where: { $0.key == "SCAL" && $0.type == 108 && $0.size == 4 }),
              scale.count == 1 || scale.count >= 5 else { return result }
        if let fix = entries.first(where: { $0.key == "GPSF" }) {
            guard fix.type == 76, fix.value.count == 4,
                  (2...3).contains(fix.value.uint(0, 4)) else { return result }
        }
        let latScale = Double(Int32(bitPattern: UInt32(scale.value.uint(0, 4))))
        let lonScale = Double(Int32(bitPattern: UInt32(scale.value.uint(scale.count == 1 ? 0 : 4, 4))))
        guard latScale > 0, lonScale > 0 else { return result }
        for index in 0..<gps.count {
            let latitude = Double(Int32(bitPattern: UInt32(gps.value.uint(index * 20, 4)))) / latScale
            let longitude = Double(Int32(bitPattern: UInt32(gps.value.uint(index * 20 + 4, 4)))) / lonScale
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            let delta = Double(index) * duration / Double(gps.count)
            result.append(CameraGPSSample(playbackTime: playbackTime + delta,
                                          timestamp: timestamp.addingTimeInterval(delta), coordinate: coordinate))
        }
        return result
    }

    private static func utcDate(_ data: Data) -> Date? {
        // GPSU: yymmddhhmmss.sss (UTC). Reject malformed/calendar-normalized dates.
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
        guard text.count == 16 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss.SSS"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}

/// Reads only indexed gpmd payloads, never decodes video. A mapped MP4 avoids
/// loading video bytes into memory. Unsupported/absent telemetry yields [].
enum CameraGPSReader {
    static func read(url: URL) throws -> [CameraGPSSample] {
        try read(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    enum ReadError: LocalizedError {
        case malformed
        var errorDescription: String? { "カメラのGPS記録を読み取れませんでした（未対応または破損した動画）" }
    }

    private struct Box {
        let type: String
        let body: Range<Int>
    }

    private static func boxes(_ data: Data, in range: Range<Int>) throws -> [Box] {
        var cursor = range.lowerBound
        var result: [Box] = []
        while cursor < range.upperBound {
            guard range.upperBound - cursor >= 8 else { throw ReadError.malformed }
            let size32 = data.uint(cursor, 4)
            let header = size32 == 1 ? 16 : 8
            guard range.upperBound - cursor >= header else { throw ReadError.malformed }
            let length = size32 == 1 ? data.uint(cursor + 8, 8) : size32 == 0 ? UInt64(range.upperBound - cursor) : size32
            guard length >= header, length <= UInt64(range.upperBound - cursor) else { throw ReadError.malformed }
            result.append(Box(type: String(decoding: data[cursor + 4..<cursor + 8], as: UTF8.self),
                              body: cursor + header..<cursor + Int(length)))
            cursor += Int(length)
        }
        return result
    }

    static func read(data: Data) throws -> [CameraGPSSample] {
        guard let moov = try boxes(data, in: 0..<data.count).first(where: { $0.type == "moov" }) else { return [] }
        let movie = try boxes(data, in: moov.body)
        var result: [CameraGPSSample] = []
        for track in movie.filter({ $0.type == "trak" }) {
            let children = try boxes(data, in: track.body)
            guard let mdia = children.first(where: { $0.type == "mdia" }) else { continue }
            let media = try boxes(data, in: mdia.body)
            guard let minf = media.first(where: { $0.type == "minf" }),
                  let stbl = try boxes(data, in: minf.body).first(where: { $0.type == "stbl" }) else { continue }
            let table = try boxes(data, in: stbl.body)
            guard let stsd = table.first(where: { $0.type == "stsd" }), stsd.body.count >= 8 else { continue }
            let descriptions = try boxes(data, in: stsd.body.lowerBound + 8..<stsd.body.upperBound)
            let gpsDescriptions = Set(descriptions.enumerated().filter { $0.element.type == "gpmd" }.map { $0.offset + 1 })
            guard !gpsDescriptions.isEmpty else { continue }
            guard let mdhd = media.first(where: { $0.type == "mdhd" }) else { throw ReadError.malformed }
            let md = data.subdata(in: mdhd.body)
            let timescaleOffset = md.first == 1 ? 20 : 12
            guard md.count >= timescaleOffset + 4 else { throw ReadError.malformed }
            let timescale = Double(md.uint(timescaleOffset, 4))
            guard timescale > 0 else { throw ReadError.malformed }
            var timeShift = 0.0
            if let edts = children.first(where: { $0.type == "edts" }),
               let elst = try boxes(data, in: edts.body).first(where: { $0.type == "elst" }) {
                guard let mvhd = movie.first(where: { $0.type == "mvhd" }) else { throw ReadError.malformed }
                let mv = data.subdata(in: mvhd.body)
                let offset = mv.first == 1 ? 20 : 12
                guard mv.count >= offset + 4, mv.uint(offset, 4) > 0 else { throw ReadError.malformed }
                let edits = data.subdata(in: elst.body)
                guard edits.count >= 8 else { throw ReadError.malformed }
                let wide = edits[0] == 1
                let width = wide ? 8 : 4
                let count = Int(edits.uint(4, 4))
                guard count <= (edits.count - 8) / (width * 2 + 4) else { throw ReadError.malformed }
                var emptyDuration = 0.0
                var foundMedia = false
                for index in 0..<count {
                    let start = 8 + index * (width * 2 + 4)
                    let raw = edits.uint(start + width, width)
                    let mediaTime = wide ? Int64(bitPattern: raw) : Int64(Int32(bitPattern: UInt32(raw)))
                    guard edits.uint(start + width * 2, 4) == 0x00010000, !foundMedia else { throw ReadError.malformed }
                    if mediaTime == -1 {
                        emptyDuration += Double(edits.uint(start, width)) / Double(mv.uint(offset, 4))
                    } else {
                        guard mediaTime >= 0 else { throw ReadError.malformed }
                        timeShift = emptyDuration - Double(mediaTime) / timescale
                        foundMedia = true
                    }
                }
            }
            func tableData(_ key: String) throws -> Data {
                guard let box = table.first(where: { $0.type == key }) else { throw ReadError.malformed }
                return data.subdata(in: box.body)
            }
            func rows(_ key: String, width: Int) throws -> [[UInt64]] {
                let bytes = try tableData(key)
                guard bytes.count >= 8 else { throw ReadError.malformed }
                let count = Int(bytes.uint(4, 4))
                guard count <= (bytes.count - 8) / (width * 4) else { throw ReadError.malformed }
                return (0..<count).map { row in (0..<width).map { bytes.uint(8 + row * width * 4 + $0 * 4, 4) } }
            }
            let timing = try rows("stts", width: 2)
            let chunks = try rows("stsc", width: 3)
            let sizes = try tableData("stsz")
            guard sizes.count >= 12 else { throw ReadError.malformed }
            let fixedSize = Int(sizes.uint(4, 4))
            let sampleCount = Int(sizes.uint(8, 4))
            guard sampleCount <= data.count / 8, fixedSize > 0 || sampleCount <= (sizes.count - 12) / 4 else { throw ReadError.malformed }
            let wide = table.contains(where: { $0.type == "co64" })
            let offsets = try tableData(wide ? "co64" : "stco")
            let width = wide ? 8 : 4
            guard offsets.count >= 8 else { throw ReadError.malformed }
            let chunkCount = Int(offsets.uint(4, 4))
            guard chunkCount <= (offsets.count - 8) / width, chunks.first?.first == 1,
                  timing.allSatisfy({ $0[0] > 0 && $0[1] > 0 }),
                  timing.reduce(UInt64(0), { $0 + $1[0] }) == sampleCount else { throw ReadError.malformed }
            for (index, row) in chunks.enumerated() {
                guard row[1] > 0, row[1] <= sampleCount, row[2] > 0, row[2] <= descriptions.count,
                      row[0] <= chunkCount, index == 0 || row[0] > chunks[index - 1][0] else { throw ReadError.malformed }
            }
            var sample = 0, chunkRun = 0, timeRun = 0
            var remaining = timing.first?[0] ?? 0
            var playback = timeShift
            var lastRetained = -Double.infinity
            for chunk in 0..<chunkCount {
                while chunkRun + 1 < chunks.count && chunks[chunkRun + 1][0] <= chunk + 1 { chunkRun += 1 }
                var byteOffset = offsets.uint(8 + chunk * width, width)
                for _ in 0..<Int(chunks[chunkRun][1]) {
                    guard sample < sampleCount, timeRun < timing.count else { throw ReadError.malformed }
                    let length = fixedSize > 0 ? fixedSize : Int(sizes.uint(12 + sample * 4, 4))
                    guard byteOffset <= data.count, length <= data.count - Int(byteOffset) else { throw ReadError.malformed }
                    let duration = Double(timing[timeRun][1]) / timescale
                    if gpsDescriptions.contains(Int(chunks[chunkRun][2])) {
                        let payload = data.subdata(in: Int(byteOffset)..<Int(byteOffset) + length)
                        for point in GPMFParser.parse(payload, playbackTime: playback, duration: duration)
                            where point.playbackTime >= 0 && point.playbackTime - lastRetained >= 5 {
                            result.append(point)
                            lastRetained = point.playbackTime
                        }
                    }
                    byteOffset += UInt64(length)
                    playback += duration
                    sample += 1
                    remaining -= 1
                    if remaining == 0 {
                        timeRun += 1
                        if timeRun < timing.count { remaining = timing[timeRun][0] }
                    }
                }
            }
            guard sample == sampleCount else { throw ReadError.malformed }
        }
        return result.sorted { $0.playbackTime < $1.playbackTime }
    }
}

private extension Data {
    func uint(_ offset: Int, _ count: Int) -> UInt64 {
        self[offset..<offset + count].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

enum CameraGPSAlignment {
    static let warningDistanceMeters = 50.0
    struct Result {
        let offsetSeconds: Double
        let medianDistanceMeters: Double?
        let comparedSamples: Int
        var needsConfirmation: Bool { medianDistanceMeters.map { $0 > warningDistanceMeters } ?? true }
        var summary: String {
            let offset = String(format: "%+.1f秒", offsetSeconds).replacingOccurrences(of: "-", with: "−")
            return offset + " / " + (medianDistanceMeters.map { String(format: "軌跡の一致 %.1fm", $0) } ?? "軌跡の一致を確認できません（GPSの重なりなし）")
        }
    }

    static func calculate(videos: [VideoMetadata], samples: [[CameraGPSSample]], activity: [FITDataPoint]) -> Result? {
        guard videos.count == samples.count else { return nil }
        var cumulative = 0.0
        var candidates: [Double] = []
        var timed: [(CameraGPSSample, Date)] = []
        for (video, points) in zip(videos, samples) {
            if let creation = video.creationDate {
                let base = creation.addingTimeInterval(cumulative)
                for point in points where point.playbackTime >= 0 && point.playbackTime < video.duration {
                    let uncorrected = base.addingTimeInterval(point.playbackTime)
                    candidates.append(point.timestamp.timeIntervalSince(uncorrected))
                    timed.append((point, uncorrected))
                }
                cumulative += video.duration
            }
        }
        guard let offset = median(candidates) else { return nil }
        let records = activity.sorted { $0.timestamp < $1.timestamp }
        var distances: [Double] = []
        var lastTime = -Double.infinity
        for (point, uncorrected) in timed.sorted(by: { $0.1 < $1.1 }) {
            let date = uncorrected.addingTimeInterval(offset)
            guard date.timeIntervalSince1970 - lastTime >= 5 else { continue }
            lastTime = date.timeIntervalSince1970
            guard let coordinate = coordinate(at: date, records: records) else { continue }
            distances.append(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: point.coordinate.latitude, longitude: point.coordinate.longitude)))
        }
        return Result(offsetSeconds: offset, medianDistanceMeters: median(distances), comparedSamples: distances.count)
    }

    private static func coordinate(at date: Date, records: [FITDataPoint]) -> CLLocationCoordinate2D? {
        guard let first = records.first, let last = records.last, date >= first.timestamp, date <= last.timestamp else { return nil }
        var lo = 0, hi = records.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if records[mid].timestamp < date { lo = mid + 1 } else { hi = mid }
        }
        if records[lo].timestamp == date {
            return records[lo].coordinate.flatMap { CLLocationCoordinate2DIsValid($0) ? $0 : nil }
        }
        guard lo > 0, let a = records[lo - 1].coordinate, let b = records[lo].coordinate,
              CLLocationCoordinate2DIsValid(a), CLLocationCoordinate2DIsValid(b) else { return nil }
        let gap = records[lo].timestamp.timeIntervalSince(records[lo - 1].timestamp)
        guard gap > 0, gap <= TimeSync.maximumInterpolationGap else { return nil }
        let fraction = date.timeIntervalSince(records[lo - 1].timestamp) / gap
        let longitudeDelta = (b.longitude - a.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        let longitude = (a.longitude + fraction * longitudeDelta + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: a.latitude + fraction * (b.latitude - a.latitude), longitude: longitude)
    }

    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
