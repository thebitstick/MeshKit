import Foundation

public enum ProtocolError: Error, LocalizedError, Equatable {
    case truncated(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .truncated(let what): "Frame too short while reading \(what)"
        case .malformed(let what): "Malformed data: \(what)"
        }
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func take(_ n: Int, _ what: String) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw ProtocolError.truncated(what) }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    mutating func u8(_ what: String = "u8") throws -> UInt8 { try take(1, what)[0] }
    mutating func i8(_ what: String = "i8") throws -> Int8 { Int8(bitPattern: try u8(what)) }

    mutating func u16(_ what: String = "u16") throws -> UInt16 {
        let b = try take(2, what)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func i16(_ what: String = "i16") throws -> Int16 { Int16(bitPattern: try u16(what)) }

    mutating func u32(_ what: String = "u32") throws -> UInt32 {
        let b = try take(4, what)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    mutating func i32(_ what: String = "i32") throws -> Int32 { Int32(bitPattern: try u32(what)) }

    mutating func fixedString(_ n: Int, _ what: String) throws -> String {
        Self.decode(try take(n, what))
    }

    mutating func restString() -> String {
        let rest = Array(bytes[offset...])
        offset = bytes.count
        return Self.decode(rest)
    }

    mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[offset...])
    }

    private static func decode(_ b: [UInt8]) -> String {
        let end = b.firstIndex(of: 0) ?? b.endIndex
        return String(decoding: b[..<end], as: UTF8.self)
    }
}

extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendFixedString(_ s: String, width: Int) {
        var b = Array(s.utf8.prefix(width - 1))
        b += [UInt8](repeating: 0, count: width - b.count)
        append(contentsOf: b)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
