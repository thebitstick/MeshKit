import Compression
import Foundation

/// zlib streams (RFC 1950) built on the Compression framework, which only speaks raw DEFLATE.
/// The ESP ROM's inflater checks the zlib header and the Adler-32 trailer, so both are added here.
public enum ZLib {
    public static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < data.count {
            // 5552 is the largest block that cannot overflow 32 bits before reducing.
            let end = min(i + 5552, data.count)
            while i < end { a &+= UInt32(data[i]); b &+= a; i += 1 }
            a %= 65521; b %= 65521
        }
        return (b << 16) | a
    }

    public static func compress(_ data: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 128
        var out = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, capacity, src.baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        var stream: [UInt8] = [0x78, 0x9C]    // deflate, 32 KiB window, default level; (0x789C % 31 == 0)
        stream += out[0..<n]
        let sum = adler32(data)
        stream += [UInt8(sum >> 24), UInt8((sum >> 16) & 0xFF), UInt8((sum >> 8) & 0xFF), UInt8(sum & 0xFF)]
        return stream
    }

    public static func decompress(_ stream: [UInt8], expectedSize: Int) -> [UInt8]? {
        guard stream.count > 6, stream[0] & 0x0F == 8, (Int(stream[0]) << 8 | Int(stream[1])) % 31 == 0 else { return nil }
        let raw = Array(stream[2..<(stream.count - 4)])
        var out = [UInt8](repeating: 0, count: expectedSize + 64)
        let n = raw.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == expectedSize else { return nil }
        out.removeLast(out.count - n)
        let trailer = stream.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return trailer == adler32(out) ? out : nil
    }

    public static func inflate(_ stream: [UInt8], capacity: Int) -> [UInt8]? {
        guard stream.count > 6, stream[0] & 0x0F == 8, (Int(stream[0]) << 8 | Int(stream[1])) % 31 == 0 else { return nil }
        let raw = Array(stream[2..<(stream.count - 4)])
        var out = [UInt8](repeating: 0, count: capacity)
        let n = raw.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, capacity, src.baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < capacity else { return nil }
        out.removeLast(out.count - n)
        let trailer = stream.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return trailer == adler32(out) ? out : nil
    }

    public static func inflateRaw(_ raw: [UInt8], expectedSize: Int) -> [UInt8]? {
        if expectedSize == 0 { return [] }
        var out = [UInt8](repeating: 0, count: expectedSize + 1)
        let n = raw.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == expectedSize else { return nil }
        out.removeLast()
        return out
    }

    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }
}
