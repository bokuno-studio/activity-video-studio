import Foundation
import CoreLocation

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

        var errorDescription: String? {
            switch self {
            case .invalidHeader: return "FIT ファイルのヘッダーが不正です"
            case .invalidFile: return "FIT ファイル形式が不正です"
            case .unexpectedEndOfData: return "FIT ファイルが途中で途切れています"
            }
        }
    }

    func parse(url: URL) throws -> [FITDataPoint] {
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    func parse(data: Data) throws -> [FITDataPoint] {
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
                if let point = parseDataMessage(
                    data: data, offset: &offset,
                    definition: definition,
                    overrideTimestamp: nil
                ) {
                    dataPoints.append(point)
                    // Extract timestamp for compressed timestamp tracking
                    if let ts = extractTimestamp(
                        data: data, offset: fieldDataStart, definition: definition
                    ) {
                        lastTimestamp = ts
                    }
                }
            }
        }

        return dataPoints
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
