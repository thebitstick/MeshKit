import Foundation

public enum USBFrame {
    public static let toRadioMarker: UInt8 = 0x3C
    public static let fromRadioMarker: UInt8 = 0x3E
    public static let maxPayload = 1024

    public static func encode(_ payload: [UInt8], marker: UInt8 = toRadioMarker) -> Data {
        var out: [UInt8] = [marker, UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF)]
        out += payload
        return Data(out)
    }
}

/// Incremental decoder. Firmware sometimes prints debug text on the same port, so anything
/// before a marker byte is discarded and implausible lengths force a resync.
public struct FrameDecoder {
    public let marker: UInt8
    private var buffer: [UInt8] = []
    public private(set) var discardedBytes = 0

    public init(marker: UInt8 = USBFrame.fromRadioMarker) { self.marker = marker }

    public mutating func feed(_ data: Data) -> [[UInt8]] {
        buffer.append(contentsOf: data)
        var frames: [[UInt8]] = []
        while true {
            guard let start = buffer.firstIndex(of: marker) else {
                discardedBytes += buffer.count
                buffer.removeAll()
                break
            }
            if start > 0 {
                discardedBytes += start
                buffer.removeFirst(start)
            }
            guard buffer.count >= 3 else { break }
            let length = Int(buffer[1]) | Int(buffer[2]) << 8
            if length == 0 || length > USBFrame.maxPayload {
                discardedBytes += 1
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= 3 + length else { break }
            frames.append(Array(buffer[3..<3 + length]))
            buffer.removeFirst(3 + length)
        }
        return frames
    }
}
