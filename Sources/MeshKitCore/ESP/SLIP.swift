import Foundation

/// SLIP framing used by the ESP ROM bootloader and flasher stub: packets are delimited by
/// 0xC0, with 0xC0 and 0xDB inside a packet escaped as DB DC and DB DD.
public enum SLIP {
    static let end: UInt8 = 0xC0
    static let esc: UInt8 = 0xDB
    static let escEnd: UInt8 = 0xDC
    static let escEsc: UInt8 = 0xDD

    public static func encode(_ packet: [UInt8]) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(packet.count + 16)
        out.append(end)
        for b in packet {
            switch b {
            case end: out += [esc, escEnd]
            case esc: out += [esc, escEsc]
            default: out.append(b)
            }
        }
        out.append(end)
        return Data(out)
    }
}

/// Incremental SLIP decoder. Bytes outside a frame (the ROM prints a boot log at 115200 baud
/// before it starts talking) are discarded, and a bad escape drops the frame in progress.
public struct SLIPDecoder {
    private var buffer: [UInt8] = []
    private var inFrame = false
    private var inEscape = false
    public private(set) var discardedBytes = 0

    public init() {}

    public mutating func reset() {
        buffer.removeAll(); inFrame = false; inEscape = false
    }

    public mutating func feed(_ data: Data) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for b in data {
            if !inFrame {
                if b == SLIP.end { inFrame = true; buffer.removeAll(); inEscape = false } else { discardedBytes += 1 }
                continue
            }
            if inEscape {
                inEscape = false
                switch b {
                case SLIP.escEnd: buffer.append(SLIP.end)
                case SLIP.escEsc: buffer.append(SLIP.esc)
                default:
                    discardedBytes += buffer.count + 2
                    buffer.removeAll(); inFrame = false
                }
                continue
            }
            switch b {
            case SLIP.end:
                if buffer.isEmpty {
                    continue
                }
                frames.append(buffer)
                buffer.removeAll()
                inFrame = false
            case SLIP.esc:
                inEscape = true
            default:
                buffer.append(b)
            }
        }
        return frames
    }
}
