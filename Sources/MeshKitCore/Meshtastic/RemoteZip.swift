import Foundation

public struct ZipEntry: Hashable, Sendable {
    public let name: String
    public let method: UInt16
    public let crc32: UInt32
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let localHeaderOffset: Int
}

public enum ZipError: Error, LocalizedError {
    case notAZip
    case unsupported(String)
    case rangeNotSupported(Int)
    case corrupt(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: "The download is not a zip archive"
        case .unsupported(let s): "Unsupported zip feature: \(s)"
        case .rangeNotSupported(let c): "The server answered HTTP \(c) to a partial-download request"
        case .corrupt(let s): "The zip archive is damaged (\(s))"
        case .notFound(let n): "\(n) is not in the archive"
        }
    }
}

public protocol RangeSource: Sendable {
    var size: Int { get }
    func read(_ range: ClosedRange<Int>) async throws -> Data
}

public struct DataRangeSource: RangeSource {
    public let data: Data
    public var size: Int { data.count }
    public init(_ data: Data) { self.data = data }
    public func read(_ range: ClosedRange<Int>) async throws -> Data { data.subdata(in: range.lowerBound..<range.upperBound + 1) }
}

/// HTTP range reads. Refuses to continue if the server ignores the Range header, so a 200 MB archive is
/// never downloaded by accident.
public struct HTTPRangeSource: RangeSource {
    public let url: URL
    public let size: Int
    public init(url: URL, size: Int) { self.url = url; self.size = size }

    public func read(_ range: ClosedRange<Int>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        request.setValue("MeshKit", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ZipError.corrupt("no HTTP response") }
        guard http.statusCode == 206 else { throw ZipError.rangeNotSupported(http.statusCode) }
        var data = Data()
        data.reserveCapacity(range.count)
        for try await b in bytes { data.append(b) }
        guard data.count == range.count else { throw ZipError.corrupt("short range read: \(data.count) of \(range.count) bytes") }
        return data
    }
}

public actor RemoteZip {
    private let source: RangeSource
    private var cached: [ZipEntry]?

    public init(source: RangeSource) { self.source = source }
    public init(url: URL, size: Int) { self.source = HTTPRangeSource(url: url, size: size) }

    public func entries() async throws -> [ZipEntry] {
        if let cached { return cached }
        let size = source.size
        guard size >= 22 else { throw ZipError.notAZip }

        // The end-of-central-directory record is within the last 64 KiB + 22 bytes (the comment is at most 64 KiB).
        let tailStart = max(0, size - (65_535 + 22))
        let tail = [UInt8](try await source.read(tailStart...size - 1))
        guard let eocd = Self.findEOCD(tail) else { throw ZipError.notAZip }
        var r = ByteReader(Array(tail[eocd...]))
        _ = try r.u32()
        _ = try r.u16(); _ = try r.u16()
        let thisDisk = try r.u16(), total = Int(try r.u16())
        let cdSize = Int(try r.u32()), cdOffset = Int(try r.u32())
        guard thisDisk != 0xFFFF, total != 0xFFFF, cdOffset != 0xFFFF_FFFF else { throw ZipError.unsupported("ZIP64") }
        guard cdOffset + cdSize <= size else { throw ZipError.corrupt("central directory out of range") }

        let cd: [UInt8]
        if cdOffset >= tailStart {
            cd = Array(tail[(cdOffset - tailStart)..<(cdOffset - tailStart + cdSize)])
        } else {
            cd = [UInt8](try await source.read(cdOffset...cdOffset + cdSize - 1))
        }

        var entries: [ZipEntry] = []
        var p = ByteReader(cd)
        for _ in 0..<total {
            guard try p.u32("central header") == 0x0201_4B50 else { throw ZipError.corrupt("bad central directory entry") }
            _ = try p.u16(); _ = try p.u16()
            let flags = try p.u16(), method = try p.u16()
            _ = try p.u16(); _ = try p.u16()
            let crc = try p.u32(), csize = try p.u32(), usize = try p.u32()
            let nameLen = Int(try p.u16()), extraLen = Int(try p.u16()), commentLen = Int(try p.u16())
            _ = try p.u16(); _ = try p.u16(); _ = try p.u32()
            let offset = try p.u32()
            let name = String(decoding: try p.take(nameLen, "name"), as: UTF8.self)
            _ = try p.take(extraLen + commentLen, "extra")
            if flags & 1 != 0 { throw ZipError.unsupported("encrypted entries") }
            entries.append(ZipEntry(name: name, method: method, crc32: crc, compressedSize: Int(csize),
                                    uncompressedSize: Int(usize), localHeaderOffset: Int(offset)))
        }
        cached = entries
        return entries
    }

    private static func findEOCD(_ tail: [UInt8]) -> Int? {
        guard tail.count >= 22 else { return nil }
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 5, tail[i + 3] == 6 { return i }
            i -= 1
        }
        return nil
    }

    public func entry(named name: String) async throws -> ZipEntry {
        guard let e = try await entries().first(where: { $0.name == name }) else { throw ZipError.notFound(name) }
        return e
    }

    public func read(_ name: String) async throws -> Data {
        let e = try await entry(named: name)
        let size = source.size
        // Local header: 30 fixed bytes + name + extra. Over-read the variable part, then trim.
        let end = min(size - 1, e.localHeaderOffset + 30 + 2048 + e.compressedSize)
        var blob = [UInt8](try await source.read(e.localHeaderOffset...end))
        var r = ByteReader(blob)
        guard try r.u32("local header") == 0x0403_4B50 else { throw ZipError.corrupt("bad local header for \(name)") }
        _ = try r.take(22, "local header")
        let nameLen = Int(try r.u16()), extraLen = Int(try r.u16())
        let dataStart = 30 + nameLen + extraLen
        if blob.count < dataStart + e.compressedSize {
            blob = [UInt8](try await source.read(e.localHeaderOffset...min(size - 1, e.localHeaderOffset + dataStart + e.compressedSize - 1)))
        }
        guard blob.count >= dataStart + e.compressedSize else { throw ZipError.corrupt("entry \(name) runs past the end") }
        let body = Array(blob[dataStart..<dataStart + e.compressedSize])

        let plain: [UInt8]
        switch e.method {
        case 0: plain = body
        case 8:
            guard let out = ZLib.inflateRaw(body, expectedSize: e.uncompressedSize) else { throw ZipError.corrupt("\(name) did not inflate") }
            plain = out
        default: throw ZipError.unsupported("compression method \(e.method)")
        }
        guard plain.count == e.uncompressedSize, ZLib.crc32(plain) == e.crc32 else { throw ZipError.corrupt("checksum mismatch in \(name)") }
        return Data(plain)
    }
}
