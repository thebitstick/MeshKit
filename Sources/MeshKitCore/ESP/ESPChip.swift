import Foundation

public enum ESPChip: String, CaseIterable, Sendable {
    case esp32 = "ESP32"
    case esp32s2 = "ESP32-S2"
    case esp32s3 = "ESP32-S3"
    case esp32c2 = "ESP32-C2"
    case esp32c3 = "ESP32-C3"
    case esp32c6 = "ESP32-C6"
    case esp32h2 = "ESP32-H2"

    public var imageChipID: UInt16 {
        switch self {
        case .esp32: 0
        case .esp32s2: 2
        case .esp32s3: 9
        case .esp32c3: 5
        case .esp32c2: 12
        case .esp32c6: 13
        case .esp32h2: 16
        }
    }

    /// Chips whose ROM cannot report a chip ID are recognised by a value read from a fixed ROM address.
    public var magicValue: UInt32? {
        switch self {
        case .esp32: 0x00F0_1D83
        case .esp32s2: 0x0000_07C6
        default: nil
        }
    }

    public static let magicRegisterAddress: UInt32 = 0x4000_1000

    public static func name(forImageChipID id: UInt16) -> String {
        allCases.first { $0.imageChipID == id }?.rawValue ?? "an unknown chip (ID \(id))"
    }

    public static func fromChipID(_ id: UInt16) -> ESPChip? { allCases.first { $0.imageChipID == id && $0.magicValue == nil } }
    public static func fromMagic(_ value: UInt32) -> ESPChip? { allCases.first { $0.magicValue == value } }

    public var bootloaderOffset: UInt32 {
        switch self {
        case .esp32, .esp32s2: 0x1000
        default: 0x0
        }
    }

    public var stubName: String { rawValue.lowercased().replacingOccurrences(of: "-", with: "") }

    /// ESP32's ROM predates the trailing "encrypted" word on flash begin commands.
    var romFlashBeginHasEncryptedFlag: Bool { self != .esp32 }

    public var hasUSBSerialJTAG: Bool {
        switch self {
        case .esp32s3, .esp32c3, .esp32c6, .esp32h2: true
        default: false
        }
    }

    struct SPIRegisters {
        let base: UInt32
        let usr: UInt32, usr1: UInt32, usr2: UInt32
        let mosiDLen: UInt32, misoDLen: UInt32, w0: UInt32
        var cmd: UInt32 { base }
    }

    var spi: SPIRegisters {
        switch self {
        case .esp32:
            SPIRegisters(base: 0x3FF4_2000, usr: 0x1C, usr1: 0x20, usr2: 0x24, mosiDLen: 0x28, misoDLen: 0x2C, w0: 0x80)
        case .esp32s2:
            SPIRegisters(base: 0x3F40_2000, usr: 0x18, usr1: 0x1C, usr2: 0x20, mosiDLen: 0x24, misoDLen: 0x28, w0: 0x58)
        case .esp32s3, .esp32c3, .esp32c2:
            SPIRegisters(base: 0x6000_2000, usr: 0x18, usr1: 0x1C, usr2: 0x20, mosiDLen: 0x24, misoDLen: 0x28, w0: 0x58)
        case .esp32c6, .esp32h2:
            SPIRegisters(base: 0x6000_3000, usr: 0x18, usr1: 0x1C, usr2: 0x20, mosiDLen: 0x24, misoDLen: 0x28, w0: 0x58)
        }
    }
}

public struct ESPFlashID: Equatable, Sendable {
    public let raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    public var manufacturer: UInt8 { UInt8(raw & 0xFF) }
    public var deviceID: UInt16 { UInt16((raw >> 16) & 0xFF) | UInt16((raw >> 8) & 0xFF) << 8 }

    public var sizeBytes: Int? {
        let table: [UInt32: Int] = [
            0x12: 256 << 10, 0x13: 512 << 10, 0x14: 1 << 20, 0x15: 2 << 20, 0x16: 4 << 20, 0x17: 8 << 20, 0x18: 16 << 20,
            0x19: 32 << 20, 0x1A: 64 << 20, 0x1B: 128 << 20, 0x1C: 256 << 20,
            0x32: 256 << 10, 0x33: 512 << 10, 0x34: 1 << 20, 0x35: 2 << 20, 0x36: 4 << 20, 0x37: 8 << 20, 0x38: 16 << 20,
            0x39: 32 << 20, 0x3A: 64 << 20,
        ]
        let adestoSizes: [UInt32: Int] = [0x04: 512 << 10, 0x05: 1 << 20, 0x06: 2 << 20, 0x07: 4 << 20, 0x08: 8 << 20, 0x09: 16 << 20]
        if manufacturer == 0x1F { return adestoSizes[(raw >> 8) & 0x1F] }
        return table[raw >> 16]
    }

    public var description: String {
        let size = sizeBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .binary) } ?? "unknown size"
        return String(format: "mfr 0x%02X dev 0x%04X, ", manufacturer, deviceID) + size
    }
}
