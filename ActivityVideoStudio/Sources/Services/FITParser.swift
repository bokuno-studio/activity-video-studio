import Foundation
import CoreLocation
import Compression

/// Parses Garmin .FIT files and extracts record data points.
/// Supports the FIT binary protocol with Definition, Data, and Developer messages.
final class FITParser {

    // MARK: - Constants

    /// Garmin epoch: 1989-12-31 00:00:00 UTC
    private static let garminEpoch: Date = {
        var components = DateComponents()
        components.year = 1989
        components.month = 12
        components.day = 31
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private static let semicirclesToDegrees: Double = 180.0 / Double(1 << 31)
    private static let recordMessageNumber: UInt16 = 20

    // MARK: - FIT Base Types

    private enum BaseType: UInt8 {
        case enumType   = 0x00
        case sint8      = 0x01
        case uint8      = 0x02
        case sint16     = 0x83
        case uint16     = 0x84
        case sint32     = 0x85
        case uint32     = 0x86
        case string     = 0x07
        case float32    = 0x88
        case float64    = 0x89
        case uint8z     = 0x0A
        case uint16z    = 0x8B
        case uint32z    = 0x8C
        case bool       = 0x0D
        case sint64     = 0x8E
        case uint64     = 0x8F
        case uint64z    = 0x90

        var invalidValue: UInt64 {
            switch self {
            case .enumType:  return 0xFF
            case .sint8:     return 0x7F
            case .uint8:     return 0xFF
            case .sint16:    return 0x7FFF
            case .uint16:    return 0xFFFF
            case .sint32:    return 0x7FFFFFFF
            case .uint32:    return 0xFFFFFFFF
            case .string:    return 0
            case .float32:   return 0xFFFFFFFF
            case .float64:   return 0xFFFFFFFFFFFFFFFF
            case .uint8z:    return 0
            case .uint16z:   return 0
            case .uint32z:   return 0
            case .bool:      return 0xFF
            case .sint64:    return 0x7FFFFFFFFFFFFFFF
            case .uint64:    return 0xFFFFFFFFFFFFFFFF
            case .uint64z:   return 0
            }
        }
    }

    private enum RecordField: UInt8 {
        case timestamp        = 253
        case positionLat      = 0
        case positionLong     = 1
        case altitude         = 2
        case heartRate        = 3
        case cadence          = 4
        case distance         = 5
        case speed            = 6
        case grade            = 9
        case enhancedSpeed    = 73
        case enhancedAltitude = 78
        case temperature      = 13
    }

    // MARK: - Internal structures

    private struct FieldDefinition {
        let fieldNumber: UInt8
        let size: UInt8
        let baseType: UInt8
    }

    private struct DevFieldDefinition {
        let fieldNumber: UInt8
        let size: UInt8
        let devDataIndex: UInt8
    }

    private struct MessageDefinition {
        let globalMessageNumber: UInt16
        let fields: [FieldDefinition]
        let devFields: [DevFieldDefinition]
        let devFieldsSize: Int
        let littleEndian: Bool
    }

    // MARK: - Parsing

    enum ParseError: Error, LocalizedError {
        case invalidHeader
        case invalidFile
        case unexpectedEndOfData
        case invalidZipArchive
        case fitNotFoundInZip
        case encryptedZipEntry(String)
        case unsupportedZip64(String)
        case unsupportedZipCompression(String, UInt16)
        case zipDecompressionFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidHeader: return "FIT ファイルのヘッダーが不正です"
            case .invalidFile: return "FIT ファイル形式が不正です"
            case .unexpectedEndOfData: return "FIT ファイルが途中で途切れています"
            case .invalidZipArchive: return "ZIP ファイル形式が不正です"
            case .fitNotFoundInZip: return "ZIP 内に .fit ファイルが見つかりません"
            case .encryptedZipEntry(let name): return "\(name) は暗号化されているため読み込めません"
            case .unsupportedZip64(let name): return "\(name) は Zip64 形式のため読み込めません"
            case .unsupportedZipCompression(let name, let method):
                return "\(name) のZIP圧縮方式（\(method)）には対応していません"
            case .zipDecompressionFailed(let name): return "\(name) のZIP展開に失敗しました"
            }
        }
    }

    /// Heart rate zone configuration from FIT zones_target message.
    struct HRZoneConfig {
        let maxHeartRate: UInt8
        let thresholdHeartRate: UInt8

        /// Compute zone boundaries as % of max HR (Garmin default).
        var z1Max: UInt8 { UInt8(Double(maxHeartRate) * 0.60) }
        var z2Max: UInt8 { UInt8(Double(maxHeartRate) * 0.70) }
        var z3Max: UInt8 { UInt8(Double(maxHeartRate) * 0.80) }
        var z4Max: UInt8 { UInt8(Double(maxHeartRate) * 0.90) }
    }

    /// Result of parsing a FIT file.
    struct ParseResult {
        let dataPoints: [FITDataPoint]
        let hrZoneConfig: HRZoneConfig?
    }

    func parse(url: URL) throws -> ParseResult {
        let data = try Data(contentsOf: url)
        if Self.isZipData(data) || url.pathExtension.lowercased() == "zip" {
            let fitData = try Self.extractPreferredFITData(fromZip: data)
            return try parseAll(data: fitData)
        }
        return try parseAll(data: data)
    }

    func parse(data: Data) throws -> ParseResult {
        try parseAll(data: data)
    }

    /// Parse and return only data points (backward compatible).
    func parseDataPoints(url: URL) throws -> [FITDataPoint] {
        try parse(url: url).dataPoints
    }

    private func parseAll(data: Data) throws -> ParseResult {
        guard data.count >= 14 else { throw ParseError.invalidHeader }

        let headerSize = data[0]
        guard headerSize >= 12, data.count >= Int(headerSize) else {
            throw ParseError.invalidHeader
        }

        let fitSignature = String(bytes: data[8..<12], encoding: .ascii)
        guard fitSignature == ".FIT" else { throw ParseError.invalidHeader }

        let dataSize = UInt32(data[4])
            | (UInt32(data[5]) << 8)
            | (UInt32(data[6]) << 16)
            | (UInt32(data[7]) << 24)

        let dataStart = Int(headerSize)
        let dataEnd = dataStart + Int(dataSize)
        guard data.count >= dataEnd else { throw ParseError.unexpectedEndOfData }

        var offset = dataStart
        var definitions: [UInt8: MessageDefinition] = [:]
        var dataPoints: [FITDataPoint] = []
        var lastTimestamp: UInt32 = 0
        var hrZoneConfig: HRZoneConfig?

        while offset < dataEnd {
            guard offset < data.count else { throw ParseError.unexpectedEndOfData }
            let recordHeader = data[offset]
            offset += 1

            let isCompressedTimestamp = (recordHeader & 0x80) != 0

            if isCompressedTimestamp {
                let localMessageType = (recordHeader >> 5) & 0x03
                let timeOffset = UInt32(recordHeader & 0x1F)

                let timestampLow5 = lastTimestamp & 0x1F
                if timeOffset >= timestampLow5 {
                    lastTimestamp = (lastTimestamp & 0xFFFFFFE0) | timeOffset
                } else {
                    lastTimestamp = (lastTimestamp & 0xFFFFFFE0) + 0x20 + timeOffset
                }

                guard let definition = definitions[localMessageType] else {
                    // Skip: unknown local type in compressed timestamp
                    continue
                }

                let beforeOffset = offset
                if let point = parseDataMessage(
                    data: data, offset: &offset,
                    definition: definition,
                    overrideTimestamp: lastTimestamp
                ) {
                    dataPoints.append(point)
                }
                // Safety: if parseDataMessage didn't advance offset, skip the data
                if offset == beforeOffset {
                    offset += totalFieldSize(definition) + definition.devFieldsSize
                }

            } else if (recordHeader & 0x40) != 0 {
                // Definition message
                let localMessageType = recordHeader & 0x0F
                let hasDeveloperData = (recordHeader & 0x20) != 0
                let definition = try parseDefinitionMessage(
                    data: data, offset: &offset,
                    hasDeveloperData: hasDeveloperData
                )
                definitions[localMessageType] = definition

            } else {
                // Normal data message
                let localMessageType = recordHeader & 0x0F
                guard let definition = definitions[localMessageType] else {
                    // Skip unknown local message type
                    continue
                }

                let fieldDataStart = offset

                // zones_target message (global 7)
                if definition.globalMessageNumber == 7 && hrZoneConfig == nil {
                    if let config = parseZonesTarget(data: data, offset: &offset, definition: definition) {
                        hrZoneConfig = config
                    }
                } else if let point = parseDataMessage(
                    data: data, offset: &offset,
                    definition: definition,
                    overrideTimestamp: nil
                ) {
                    dataPoints.append(point)
                    if let ts = extractTimestamp(
                        data: data, offset: fieldDataStart, definition: definition
                    ) {
                        lastTimestamp = ts
                    }
                }
            }
        }

        return ParseResult(dataPoints: dataPoints, hrZoneConfig: hrZoneConfig)
    }

    // MARK: - ZIP support

    private struct ZipEntry {
        let name: String
        let flags: UInt16
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    private static func isZipData(_ data: Data) -> Bool {
        data.count >= 4
            && data[0] == 0x50
            && data[1] == 0x4B
            && data[2] == 0x03
            && data[3] == 0x04
    }

    private static func extractPreferredFITData(fromZip data: Data) throws -> Data {
        let entries = try zipCentralDirectoryEntries(in: data)
            .filter { entry in
                let lowercasedName = entry.name.lowercased()
                return lowercasedName.hasSuffix(".fit") && !lowercasedName.hasSuffix("/")
            }
        guard !entries.isEmpty else { throw ParseError.fitNotFoundInZip }

        let preferred = entries.first { entry in
            entry.name.split(separator: "/").last?
                .uppercased()
                .hasSuffix("_ACTIVITY.FIT") == true
        } ?? entries[0]

        return try extract(entry: preferred, fromZip: data)
    }

    private static func zipCentralDirectoryEntries(in data: Data) throws -> [ZipEntry] {
        let endOfCentralDirectorySignature: UInt32 = 0x06054B50
        let centralDirectorySignature: UInt32 = 0x02014B50
        guard let eocdOffset = lastOffset(ofLittleEndianSignature: endOfCentralDirectorySignature, in: data),
              eocdOffset + 22 <= data.count else {
            throw ParseError.invalidZipArchive
        }

        let entryCount = readUInt16LE(data, eocdOffset + 10)
        let centralDirectorySize = readUInt32LE(data, eocdOffset + 12)
        let centralDirectoryOffset = readUInt32LE(data, eocdOffset + 16)
        guard entryCount != 0xFFFF,
              centralDirectorySize != 0xFFFF_FFFF,
              centralDirectoryOffset != 0xFFFF_FFFF else {
            throw ParseError.unsupportedZip64("ZIP")
        }

        let start = Int(centralDirectoryOffset)
        let size = Int(centralDirectorySize)
        guard start >= 0, size >= 0, start + size <= data.count else {
            throw ParseError.invalidZipArchive
        }

        var entries: [ZipEntry] = []
        var offset = start
        let end = start + size
        while offset < end {
            guard offset + 46 <= data.count,
                  readUInt32LE(data, offset) == centralDirectorySignature else {
                throw ParseError.invalidZipArchive
            }

            let flags = readUInt16LE(data, offset + 8)
            let compressionMethod = readUInt16LE(data, offset + 10)
            let compressedSize = readUInt32LE(data, offset + 20)
            let uncompressedSize = readUInt32LE(data, offset + 24)
            let fileNameLength = Int(readUInt16LE(data, offset + 28))
            let extraLength = Int(readUInt16LE(data, offset + 30))
            let commentLength = Int(readUInt16LE(data, offset + 32))
            let localHeaderOffset = readUInt32LE(data, offset + 42)

            guard compressedSize != 0xFFFF_FFFF,
                  uncompressedSize != 0xFFFF_FFFF,
                  localHeaderOffset != 0xFFFF_FFFF else {
                let name = zipEntryName(data: data, offset: offset + 46, length: fileNameLength) ?? "ZIP"
                throw ParseError.unsupportedZip64(name)
            }

            let nameOffset = offset + 46
            let nextOffset = nameOffset + fileNameLength + extraLength + commentLength
            guard nextOffset <= data.count,
                  let name = zipEntryName(data: data, offset: nameOffset, length: fileNameLength) else {
                throw ParseError.invalidZipArchive
            }

            entries.append(ZipEntry(
                name: name,
                flags: flags,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))
            offset = nextOffset
        }

        return entries
    }

    private static func extract(entry: ZipEntry, fromZip data: Data) throws -> Data {
        guard (entry.flags & 0x0001) == 0 else {
            throw ParseError.encryptedZipEntry(entry.name)
        }

        let localHeaderSignature: UInt32 = 0x04034B50
        let localOffset = Int(entry.localHeaderOffset)
        guard localOffset + 30 <= data.count,
              readUInt32LE(data, localOffset) == localHeaderSignature else {
            throw ParseError.invalidZipArchive
        }

        let fileNameLength = Int(readUInt16LE(data, localOffset + 26))
        let extraLength = Int(readUInt16LE(data, localOffset + 28))
        let payloadOffset = localOffset + 30 + fileNameLength + extraLength
        let compressedSize = Int(entry.compressedSize)
        let uncompressedSize = Int(entry.uncompressedSize)
        guard payloadOffset >= 0,
              compressedSize >= 0,
              uncompressedSize >= 0,
              payloadOffset + compressedSize <= data.count else {
            throw ParseError.invalidZipArchive
        }

        let compressedData = Data(data[payloadOffset..<(payloadOffset + compressedSize)])
        switch entry.compressionMethod {
        case 0:
            guard compressedData.count == uncompressedSize else {
                throw ParseError.zipDecompressionFailed(entry.name)
            }
            return compressedData
        case 8:
            return try inflateRawDeflate(compressedData, uncompressedSize: uncompressedSize, name: entry.name)
        default:
            throw ParseError.unsupportedZipCompression(entry.name, entry.compressionMethod)
        }
    }

    private static func inflateRawDeflate(_ input: Data, uncompressedSize: Int, name: String) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var output = Data(count: uncompressedSize)
        let decodedCount = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    outputBuffer.count,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    inputBuffer.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedCount == uncompressedSize else {
            throw ParseError.zipDecompressionFailed(name)
        }
        return output
    }

    private static func lastOffset(ofLittleEndianSignature signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var offset = data.count - 4
        while offset >= 0 {
            if readUInt32LE(data, offset) == signature {
                return offset
            }
            if offset == 0 { break }
            offset -= 1
        }
        return nil
    }

    private static func zipEntryName(data: Data, offset: Int, length: Int) -> String? {
        guard offset >= 0, length >= 0, offset + length <= data.count else { return nil }
        return String(data: data[offset..<(offset + length)], encoding: .utf8)
            ?? String(data: data[offset..<(offset + length)], encoding: .shiftJIS)
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - zones_target parsing

    private func parseZonesTarget(data: Data, offset: inout Int, definition: MessageDefinition) -> HRZoneConfig? {
        let fieldsSize = totalFieldSize(definition)
        let totalSize = fieldsSize + definition.devFieldsSize
        guard offset + totalSize <= data.count else { offset += totalSize; return nil }

        var maxHR: UInt8?
        var thresholdHR: UInt8?

        for field in definition.fields {
            let fieldStart = offset
            offset += Int(field.size)

            switch field.fieldNumber {
            case 1: // max_heart_rate
                if field.size == 1 && data[fieldStart] != 0xFF {
                    maxHR = data[fieldStart]
                }
            case 2: // threshold_heart_rate
                if field.size == 1 && data[fieldStart] != 0xFF {
                    thresholdHR = data[fieldStart]
                }
            default: break
            }
        }
        offset += definition.devFieldsSize

        guard let mhr = maxHR else { return nil }
        return HRZoneConfig(maxHeartRate: mhr, thresholdHeartRate: thresholdHR ?? mhr)
    }

    // MARK: - Private parsing helpers

    private func parseDefinitionMessage(
        data: Data, offset: inout Int, hasDeveloperData: Bool
    ) throws -> MessageDefinition {
        guard offset + 5 <= data.count else { throw ParseError.unexpectedEndOfData }

        _ = data[offset]       // reserved
        let architecture = data[offset + 1]
        let littleEndian = architecture == 0

        let globalMessageNumber: UInt16
        if littleEndian {
            globalMessageNumber = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
        } else {
            globalMessageNumber = (UInt16(data[offset + 2]) << 8) | UInt16(data[offset + 3])
        }

        let fieldCount = Int(data[offset + 4])
        offset += 5

        guard offset + fieldCount * 3 <= data.count else {
            throw ParseError.unexpectedEndOfData
        }

        var fields: [FieldDefinition] = []
        for _ in 0..<fieldCount {
            let fieldNum = data[offset]
            let fieldSize = data[offset + 1]
            let baseType = data[offset + 2]
            fields.append(FieldDefinition(
                fieldNumber: fieldNum,
                size: fieldSize,
                baseType: baseType
            ))
            offset += 3
        }

        // Developer fields
        var devFieldsSize = 0
        var devFields: [DevFieldDefinition] = []
        if hasDeveloperData {
            guard offset < data.count else { throw ParseError.unexpectedEndOfData }
            let devFieldCount = Int(data[offset])
            offset += 1
            guard offset + devFieldCount * 3 <= data.count else {
                throw ParseError.unexpectedEndOfData
            }
            for _ in 0..<devFieldCount {
                let devFieldNum = data[offset]
                let devSize = data[offset + 1]
                let devIdx = data[offset + 2]
                devFields.append(DevFieldDefinition(
                    fieldNumber: devFieldNum,
                    size: devSize,
                    devDataIndex: devIdx
                ))
                devFieldsSize += Int(devSize)
                offset += 3
            }
        }

        return MessageDefinition(
            globalMessageNumber: globalMessageNumber,
            fields: fields,
            devFields: devFields,
            devFieldsSize: devFieldsSize,
            littleEndian: littleEndian
        )
    }

    private func parseDataMessage(
        data: Data,
        offset: inout Int,
        definition: MessageDefinition,
        overrideTimestamp: UInt32?
    ) -> FITDataPoint? {
        let fieldsSize = totalFieldSize(definition)
        let totalSize = fieldsSize + definition.devFieldsSize
        guard offset + totalSize <= data.count else {
            // Not enough data, skip
            return nil
        }

        // Only parse record messages (global message number 20)
        guard definition.globalMessageNumber == FITParser.recordMessageNumber else {
            offset += totalSize
            return nil
        }

        var timestamp: UInt32?
        var positionLat: Int32?
        var positionLong: Int32?
        var heartRate: UInt8?
        var speed: UInt16?
        var enhancedSpeed: UInt32?
        var altitude: UInt16?
        var enhancedAltitude: UInt32?
        var cadence: UInt8?
        var distance: UInt32?
        var grade: Int16?
        var temperature: Int8?

        for field in definition.fields {
            let fieldStart = offset
            let fieldEnd = fieldStart + Int(field.size)
            guard fieldEnd <= data.count else {
                return nil
            }

            let baseType = BaseType(rawValue: field.baseType)
            let isInvalid = isFieldInvalid(
                data: data, offset: fieldStart,
                size: Int(field.size), baseType: baseType
            )

            if !isInvalid {
                switch RecordField(rawValue: field.fieldNumber) {
                case .timestamp:
                    if field.size >= 4 {
                        timestamp = readUInt32(data: data, offset: fieldStart, littleEndian: definition.littleEndian)
                    }
                case .positionLat:
                    if field.size >= 4 {
                        positionLat = readSInt32(data: data, offset: fieldStart, littleEndian: definition.littleEndian)
                    }
                case .positionLong:
                    if field.size >= 4 {
                        positionLong = readSInt32(data: data, offset: fieldStart, littleEndian: definition.littleEndian)
                    }
                case .heartRate:
                    heartRate = data[fieldStart]
                case .cadence:
                    cadence = data[fieldStart]
                case .speed:
                    if field.size >= 2 {
                        speed = readUInt16(data: data, offset: fieldStart, littleEndian: definition.littleEndian)
                    }
                case .enhancedSpeed:
                    if field.size >= 4 {
                        enhancedSpeed = readUInt32(data: data, offset: fieldStart, littleEndian: definition.littleEndian)
                    }
                case .altitude:
                    if field.size >= 2 {
                        altitude = readUInt16(data: data, offset: fieldStart, littleEndian: definition.littleEndian)
                    }
                case .enhancedAltitude:
                    if field.size >= 4 {
                        enhancedAltitude = readUInt32(data: data, offset: fieldStart, littleEndian: definition.littleEndian)
                    }
                case .distance:
                    if field.size >= 4 {
                        distance = readUInt32(data: data, offset: fieldStart, littleEndian: definition.littleEndian)
                    }
                case .grade:
                    if field.size >= 2 {
                        grade = readSInt16(data: data, offset: fieldStart, littleEndian: definition.littleEndian)
                    }
                case .temperature:
                    let raw = Int8(bitPattern: data[fieldStart])
                    if raw != 0x7F { temperature = raw }
                case .none:
                    break
                }
            }

            offset = fieldEnd
        }

        // Parse developer fields (CORE body temperature)
        var coreTemp: Double?
        var skinTemp: Double?
        for devField in definition.devFields {
            let devStart = offset
            let devEnd = devStart + Int(devField.size)
            guard devEnd <= data.count else { break }

            if devField.devDataIndex == 0 && devField.size == 4 {
                let rawBits = readUInt32(data: data, offset: devStart, littleEndian: definition.littleEndian)
                let floatVal = Float(bitPattern: rawBits)
                if !floatVal.isNaN && floatVal > 0 && floatVal < 50 {
                    switch devField.fieldNumber {
                    case 0:  coreTemp = Double(floatVal)  // core_temperature
                    case 10: skinTemp = Double(floatVal)  // skin_temperature
                    default: break
                    }
                }
            }
            offset = devEnd
        }

        // Resolve timestamp
        let resolvedTimestamp = overrideTimestamp ?? timestamp
        guard let ts = resolvedTimestamp else { return nil }
        let date = FITParser.garminEpoch.addingTimeInterval(TimeInterval(ts))

        // Resolve coordinate
        var coordinate: CLLocationCoordinate2D?
        if let lat = positionLat, let long = positionLong,
           lat != Int32(bitPattern: 0x7FFFFFFF),
           long != Int32(bitPattern: 0x7FFFFFFF) {
            coordinate = CLLocationCoordinate2D(
                latitude: Double(lat) * FITParser.semicirclesToDegrees,
                longitude: Double(long) * FITParser.semicirclesToDegrees
            )
        }

        let resolvedSpeed: Double?
        if let es = enhancedSpeed {
            resolvedSpeed = Double(es) / 1000.0
        } else if let s = speed {
            resolvedSpeed = Double(s) / 1000.0
        } else {
            resolvedSpeed = nil
        }

        let resolvedAltitude: Double?
        if let ea = enhancedAltitude {
            resolvedAltitude = Double(ea) / 5.0 - 500.0
        } else if let a = altitude {
            resolvedAltitude = Double(a) / 5.0 - 500.0
        } else {
            resolvedAltitude = nil
        }

        let resolvedDistance = distance.map { Double($0) / 100.0 }
        let resolvedGrade = grade.map { Double($0) / 100.0 }

        return FITDataPoint(
            timestamp: date,
            coordinate: coordinate,
            heartRate: heartRate,
            speed: resolvedSpeed,
            altitude: resolvedAltitude,
            cadence: cadence,
            distance: resolvedDistance,
            grade: resolvedGrade,
            temperature: temperature,
            coreTemperature: coreTemp,
            skinTemperature: skinTemp
        )
    }

    // MARK: - Binary read helpers

    private func readUInt16(data: Data, offset: Int, littleEndian: Bool) -> UInt16 {
        if littleEndian {
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        } else {
            return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        }
    }

    private func readSInt16(data: Data, offset: Int, littleEndian: Bool) -> Int16 {
        Int16(bitPattern: readUInt16(data: data, offset: offset, littleEndian: littleEndian))
    }

    private func readUInt32(data: Data, offset: Int, littleEndian: Bool) -> UInt32 {
        if littleEndian {
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        } else {
            return (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
        }
    }

    private func readSInt32(data: Data, offset: Int, littleEndian: Bool) -> Int32 {
        Int32(bitPattern: readUInt32(data: data, offset: offset, littleEndian: littleEndian))
    }

    private func isFieldInvalid(data: Data, offset: Int, size: Int, baseType: BaseType?) -> Bool {
        guard let bt = baseType else { return false }
        switch size {
        case 1:
            return UInt64(data[offset]) == bt.invalidValue
        case 2:
            let val = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            return UInt64(val) == bt.invalidValue
        case 4:
            let val = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            return UInt64(val) == bt.invalidValue
        default:
            return false
        }
    }

    private func totalFieldSize(_ definition: MessageDefinition) -> Int {
        definition.fields.reduce(0) { $0 + Int($1.size) }
    }

    private func extractTimestamp(data: Data, offset: Int, definition: MessageDefinition) -> UInt32? {
        var fieldOffset = offset
        for field in definition.fields {
            if field.fieldNumber == RecordField.timestamp.rawValue, field.size >= 4 {
                return readUInt32(data: data, offset: fieldOffset, littleEndian: definition.littleEndian)
            }
            fieldOffset += Int(field.size)
        }
        return nil
    }
}
