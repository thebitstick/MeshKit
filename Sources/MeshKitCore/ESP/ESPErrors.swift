import Foundation

public enum ESPError: Error, LocalizedError, Equatable {
    case timeout(String)
    case noSync(String)
    case invalidResponse(String)
    case status(operation: String, code: UInt16)
    case unsupportedCommand(String)
    case unsupportedChip(String)
    case notInStubMode(String)
    case stubUnavailable(String)
    case stubFailed(String)
    case imageForDifferentChip(found: String, expected: String)
    case imageTooLarge(size: Int, flashSize: Int)
    case verifyFailed(expected: String, actual: String)
    case readCorrupt(String)
    case emptyImage

    public var errorDescription: String? {
        switch self {
        case .timeout(let what): "Timed out waiting for the chip (\(what))"
        case .noSync(let hint): "Couldn't enter the bootloader. \(hint)"
        case .invalidResponse(let what): "Unexpected reply from the chip: \(what)"
        case .status(let op, let code): "Failed to \(op): \(Self.describe(code: code)) (0x\(String(code, radix: 16, uppercase: true)))"
        case .unsupportedCommand(let op): "The bootloader doesn't support \(op)"
        case .unsupportedChip(let what): "Unrecognised or unsupported chip (\(what))"
        case .notInStubMode(let op): "\(op) needs the flasher stub"
        case .stubUnavailable(let chip): "No flasher stub is bundled for \(chip)"
        case .stubFailed(let what): "The flasher stub didn't start: \(what)"
        case .imageForDifferentChip(let found, let expected): "This image is for \(found), but the connected chip is \(expected)"
        case .imageTooLarge(let size, let flash): "The image (\(size) bytes) doesn't fit in the \(flash)-byte flash"
        case .verifyFailed(let e, let a): "Verification failed: flash MD5 \(a.prefix(8))… doesn't match the image \(e.prefix(8))…"
        case .readCorrupt(let what): "Flash read failed: \(what)"
        case .emptyImage: "The image is empty"
        }
    }

    /// ROM error codes are `0x1xx`; stub errors are `0xCxxx`/`0xFF00`. The reply carries the
    /// status byte then the error byte, which read big-endian gives these values.
    static func describe(code: UInt16) -> String {
        let table: [UInt16: String] = [
            0x100: "undefined error", 0x101: "invalid parameter", 0x102: "out of memory", 0x103: "failed to send message",
            0x104: "failed to receive message", 0x105: "invalid message format", 0x106: "command failed",
            0x107: "checksum error", 0x108: "flash write error", 0x109: "flash read error",
            0x10A: "flash read length error", 0x10B: "deflate failed", 0x10C: "deflate Adler-32 error",
            0x10D: "deflate parameter error", 0x10E: "invalid RAM binary size", 0x10F: "invalid RAM binary address",
            0xC000: "bad data length", 0xC100: "bad data checksum", 0xC200: "bad block size", 0xC300: "invalid command",
            0xC400: "SPI operation failed", 0xC500: "SPI unlock failed", 0xC600: "not in flash mode",
            0xC700: "inflate error", 0xC800: "not enough data", 0xC900: "too much data", 0xFF00: "command not implemented",
        ]
        return table[code] ?? "unknown error"
    }
}
