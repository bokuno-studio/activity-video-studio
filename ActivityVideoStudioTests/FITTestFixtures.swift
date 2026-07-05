import Foundation

enum FITTestFixtures {
    struct Field {
        let number: UInt8
        let size: UInt8
        let baseType: UInt8
    }

    struct DevField {
        let number: UInt8
        let size: UInt8
        let developerDataIndex: UInt8
    }

    static func developerTemperatureFIT() -> Data {
        var records = Data()
        records.append(definition(local: 0, global: 207, fields: [
            Field(number: 3, size: 1, baseType: 0x02)
        ]))
        records.append(dataMessage(local: 0, fields: [
            Data([0])
        ]))

        records.append(definition(local: 1, global: 206, fields: [
            Field(number: 0, size: 1, baseType: 0x02),
            Field(number: 1, size: 1, baseType: 0x02),
            Field(number: 2, size: 1, baseType: 0x02),
            Field(number: 3, size: 24, baseType: 0x07),
            Field(number: 8, size: 4, baseType: 0x07)
        ]))
        records.append(fieldDescription(fieldNumber: 0, name: "power_watts", units: "W"))
        records.append(fieldDescription(fieldNumber: 1, name: "core_temperature", units: "C"))
        records.append(fieldDescription(fieldNumber: 10, name: "skin_temperature", units: "C"))

        records.append(definition(local: 2, global: 20, fields: [
            Field(number: 253, size: 4, baseType: 0x86)
        ], devFields: [
            DevField(number: 0, size: 4, developerDataIndex: 0),
            DevField(number: 1, size: 4, developerDataIndex: 0),
            DevField(number: 10, size: 4, developerDataIndex: 0)
        ]))
        records.append(dataMessage(local: 2, fields: [
            uint32(1_000),
            float32(37.2),
            float32(38.1),
            float32(32.5)
        ]))
        return fitFile(records: records)
    }

    static func legacyDeveloperTemperatureFIT() -> Data {
        var records = Data()
        records.append(definition(local: 0, global: 20, fields: [
            Field(number: 253, size: 4, baseType: 0x86)
        ], devFields: [
            DevField(number: 0, size: 4, developerDataIndex: 0),
            DevField(number: 10, size: 4, developerDataIndex: 0)
        ]))
        records.append(dataMessage(local: 0, fields: [
            uint32(1_000),
            float32(37.9),
            float32(31.8)
        ]))
        return fitFile(records: records)
    }

    static func compressedTimestampFIT() -> Data {
        var records = Data()
        records.append(definition(local: 0, global: 23, fields: [
            Field(number: 253, size: 4, baseType: 0x86)
        ]))
        records.append(dataMessage(local: 0, fields: [
            uint32(1_000)
        ]))

        records.append(definition(local: 1, global: 20, fields: [
            Field(number: 3, size: 1, baseType: 0x02)
        ]))

        let timestamp: UInt32 = 1_005
        records.append(0x80 | (1 << 5) | UInt8(timestamp & 0x1F))
        records.append(150)
        return fitFile(records: records)
    }

    static func compressedTimestampWrapFIT() -> Data {
        var records = Data()
        records.append(definition(local: 0, global: 23, fields: [
            Field(number: 253, size: 4, baseType: 0x86)
        ]))
        records.append(dataMessage(local: 0, fields: [
            uint32(1_023)
        ]))

        records.append(definition(local: 1, global: 20, fields: [
            Field(number: 3, size: 1, baseType: 0x02)
        ]))

        let wrappedTimestamp: UInt32 = 1_026
        records.append(0x80 | (1 << 5) | UInt8(wrappedTimestamp & 0x1F))
        records.append(151)
        return fitFile(records: records)
    }

    static func simpleFIT(timestamp: UInt32 = 1_000, speed: UInt16 = 1_000) -> Data {
        var records = Data()
        records.append(definition(local: 0, global: 20, fields: [
            Field(number: 253, size: 4, baseType: 0x86),
            Field(number: 6, size: 2, baseType: 0x84)
        ]))
        records.append(dataMessage(local: 0, fields: [
            uint32(timestamp),
            uint16(speed)
        ]))
        return fitFile(records: records)
    }

    static func multiRecordFIT() -> Data {
        var records = Data()
        records.append(definition(local: 0, global: 20, fields: [
            Field(number: 253, size: 4, baseType: 0x86),
            Field(number: 6, size: 2, baseType: 0x84)
        ]))
        records.append(dataMessage(local: 0, fields: [
            uint32(1_000),
            uint16(1_000)
        ]))
        records.append(dataMessage(local: 0, fields: [
            uint32(1_001),
            uint16(2_500)
        ]))
        return fitFile(records: records)
    }

    static func bigEndianScaledRecordFIT() -> Data {
        var records = Data()
        records.append(definition(local: 0, global: 20, fields: [
            Field(number: 253, size: 4, baseType: 0x86),
            Field(number: 0, size: 4, baseType: 0x85),
            Field(number: 1, size: 4, baseType: 0x85),
            Field(number: 3, size: 1, baseType: 0x02),
            Field(number: 6, size: 2, baseType: 0x84),
            Field(number: 2, size: 2, baseType: 0x84),
            Field(number: 4, size: 1, baseType: 0x02),
            Field(number: 5, size: 4, baseType: 0x86),
            Field(number: 9, size: 2, baseType: 0x83),
            Field(number: 13, size: 1, baseType: 0x01)
        ], littleEndian: false))
        records.append(dataMessage(local: 0, fields: [
            uint32BE(1_234),
            sint32BE(1_073_741_824),
            sint32BE(-536_870_912),
            Data([154]),
            uint16BE(1_234),
            uint16BE(2_710),
            Data([88]),
            uint32BE(12_345),
            sint16BE(-321),
            Data([UInt8(bitPattern: Int8(-5))])
        ]))
        return fitFile(records: records)
    }

    static func simpleFITWithZeroCRCs() -> Data {
        var data = simpleFIT()
        data[12] = 0
        data[13] = 0
        data[data.count - 2] = 0
        data[data.count - 1] = 0
        return data
    }

    static func legacyFallbackBlockedByFieldDescriptionFIT() -> Data {
        var records = Data()
        records.append(definition(local: 0, global: 207, fields: [
            Field(number: 3, size: 1, baseType: 0x02)
        ]))
        records.append(dataMessage(local: 0, fields: [
            Data([0])
        ]))

        records.append(definition(local: 1, global: 206, fields: [
            Field(number: 0, size: 1, baseType: 0x02),
            Field(number: 1, size: 1, baseType: 0x02),
            Field(number: 2, size: 1, baseType: 0x02),
            Field(number: 3, size: 24, baseType: 0x07),
            Field(number: 8, size: 4, baseType: 0x07)
        ]))
        records.append(fieldDescription(fieldNumber: 0, name: "power_watts", units: "W"))

        records.append(definition(local: 2, global: 20, fields: [
            Field(number: 253, size: 4, baseType: 0x86)
        ], devFields: [
            DevField(number: 0, size: 4, developerDataIndex: 0)
        ]))
        records.append(dataMessage(local: 2, fields: [
            uint32(1_000),
            float32(37.9)
        ]))
        return fitFile(records: records)
    }

    static func zipWithPreferredActivityFIT() -> Data {
        storedZip(entries: [
            (name: "first.fit", payload: simpleFIT(timestamp: 1_000, speed: 1_000)),
            (name: "GARMIN/20260705_ACTIVITY.FIT", payload: simpleFIT(timestamp: 2_000, speed: 3_000))
        ])
    }

    static func zipWithEmptyDeflateFITEntry() -> Data {
        let name = Array("broken.fit".utf8)
        var zip = Data()
        let localHeaderOffset = UInt32(zip.count)

        zip.appendUInt32LE(0x0403_4B50)
        zip.appendUInt16LE(20)
        zip.appendUInt16LE(0)
        zip.appendUInt16LE(8)
        zip.appendUInt16LE(0)
        zip.appendUInt16LE(0)
        zip.appendUInt32LE(0)
        zip.appendUInt32LE(0)
        zip.appendUInt32LE(10)
        zip.appendUInt16LE(UInt16(name.count))
        zip.appendUInt16LE(0)
        zip.append(contentsOf: name)

        let centralDirectoryOffset = UInt32(zip.count)
        var centralDirectory = Data()
        centralDirectory.appendUInt32LE(0x0201_4B50)
        centralDirectory.appendUInt16LE(20)
        centralDirectory.appendUInt16LE(20)
        centralDirectory.appendUInt16LE(0)
        centralDirectory.appendUInt16LE(8)
        centralDirectory.appendUInt16LE(0)
        centralDirectory.appendUInt16LE(0)
        centralDirectory.appendUInt32LE(0)
        centralDirectory.appendUInt32LE(0)
        centralDirectory.appendUInt32LE(10)
        centralDirectory.appendUInt16LE(UInt16(name.count))
        centralDirectory.appendUInt16LE(0)
        centralDirectory.appendUInt16LE(0)
        centralDirectory.appendUInt16LE(0)
        centralDirectory.appendUInt16LE(0)
        centralDirectory.appendUInt32LE(0)
        centralDirectory.appendUInt32LE(localHeaderOffset)
        centralDirectory.append(contentsOf: name)
        zip.append(centralDirectory)

        zip.appendUInt32LE(0x0605_4B50)
        zip.appendUInt16LE(0)
        zip.appendUInt16LE(0)
        zip.appendUInt16LE(1)
        zip.appendUInt16LE(1)
        zip.appendUInt32LE(UInt32(centralDirectory.count))
        zip.appendUInt32LE(centralDirectoryOffset)
        zip.appendUInt16LE(0)
        return zip
    }

    private static func fieldDescription(fieldNumber: UInt8, name: String, units: String) -> Data {
        dataMessage(local: 1, fields: [
            Data([0]),
            Data([fieldNumber]),
            Data([0x88]),
            string(name, size: 24),
            string(units, size: 4)
        ])
    }

    private static func definition(
        local: UInt8,
        global: UInt16,
        fields: [Field],
        devFields: [DevField] = [],
        littleEndian: Bool = true
    ) -> Data {
        var data = Data()
        data.append(0x40 | (devFields.isEmpty ? 0 : 0x20) | (local & 0x0F))
        data.append(0)
        data.append(littleEndian ? 0 : 1)
        if littleEndian {
            data.appendUInt16LE(global)
        } else {
            data.appendUInt16BE(global)
        }
        data.append(UInt8(fields.count))
        for field in fields {
            data.append(field.number)
            data.append(field.size)
            data.append(field.baseType)
        }
        if !devFields.isEmpty {
            data.append(UInt8(devFields.count))
            for field in devFields {
                data.append(field.number)
                data.append(field.size)
                data.append(field.developerDataIndex)
            }
        }
        return data
    }

    private static func dataMessage(local: UInt8, fields: [Data]) -> Data {
        var data = Data([local & 0x0F])
        for field in fields {
            data.append(field)
        }
        return data
    }

    private static func fitFile(records: Data) -> Data {
        var header = Data()
        header.append(14)
        header.append(16)
        header.appendUInt16LE(0)
        header.appendUInt32LE(UInt32(records.count))
        header.append(contentsOf: Array(".FIT".utf8))
        let headerCRC = fitCRC(header)
        header.appendUInt16LE(headerCRC)

        var file = header
        file.append(records)
        file.appendUInt16LE(fitCRC(file))
        return file
    }

    private static func storedZip(entries: [(name: String, payload: Data)]) -> Data {
        var zip = Data()
        var centralDirectory = Data()

        for entry in entries {
            let name = Array(entry.name.utf8)
            let localHeaderOffset = UInt32(zip.count)
            let size = UInt32(entry.payload.count)

            zip.appendUInt32LE(0x0403_4B50)
            zip.appendUInt16LE(20)
            zip.appendUInt16LE(0)
            zip.appendUInt16LE(0)
            zip.appendUInt16LE(0)
            zip.appendUInt16LE(0)
            zip.appendUInt32LE(0)
            zip.appendUInt32LE(size)
            zip.appendUInt32LE(size)
            zip.appendUInt16LE(UInt16(name.count))
            zip.appendUInt16LE(0)
            zip.append(contentsOf: name)
            zip.append(entry.payload)

            centralDirectory.appendUInt32LE(0x0201_4B50)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(size)
            centralDirectory.appendUInt32LE(size)
            centralDirectory.appendUInt16LE(UInt16(name.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(contentsOf: name)
        }

        let centralDirectoryOffset = UInt32(zip.count)
        zip.append(centralDirectory)
        zip.appendUInt32LE(0x0605_4B50)
        zip.appendUInt16LE(0)
        zip.appendUInt16LE(0)
        zip.appendUInt16LE(UInt16(entries.count))
        zip.appendUInt16LE(UInt16(entries.count))
        zip.appendUInt32LE(UInt32(centralDirectory.count))
        zip.appendUInt32LE(centralDirectoryOffset)
        zip.appendUInt16LE(0)
        return zip
    }

    private static func string(_ value: String, size: Int) -> Data {
        var bytes = Array(value.utf8.prefix(size))
        if bytes.count < size {
            bytes.append(contentsOf: repeatElement(0, count: size - bytes.count))
        }
        return Data(bytes)
    }

    private static func uint16(_ value: UInt16) -> Data {
        var data = Data()
        data.appendUInt16LE(value)
        return data
    }

    private static func uint16BE(_ value: UInt16) -> Data {
        var data = Data()
        data.appendUInt16BE(value)
        return data
    }

    private static func sint16BE(_ value: Int16) -> Data {
        uint16BE(UInt16(bitPattern: value))
    }

    private static func uint32(_ value: UInt32) -> Data {
        var data = Data()
        data.appendUInt32LE(value)
        return data
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        var data = Data()
        data.appendUInt32BE(value)
        return data
    }

    private static func sint32BE(_ value: Int32) -> Data {
        uint32BE(UInt32(bitPattern: value))
    }

    private static func float32(_ value: Float) -> Data {
        uint32(value.bitPattern)
    }

    private static func fitCRC(_ data: Data) -> UInt16 {
        let crcTable: [UInt16] = [
            0x0000, 0xCC01, 0xD801, 0x1400,
            0xF001, 0x3C00, 0x2800, 0xE401,
            0xA001, 0x6C00, 0x7800, 0xB401,
            0x5000, 0x9C01, 0x8801, 0x4400
        ]
        var crc: UInt16 = 0
        for var byte in data {
            var tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int(byte & 0xF)]

            tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            byte >>= 4
            crc = crc ^ tmp ^ crcTable[Int(byte & 0xF)]
        }
        return crc
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
