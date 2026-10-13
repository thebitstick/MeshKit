import Foundation

public protocol ESPSerial: ByteTransport {
    func setLines(dtr: Bool, rts: Bool) throws
    func setBaudRate(_ baud: Int) throws
}

extension SerialPort: ESPSerial {
    // Darwin <sys/ttycom.h>; the _IOR/_IOW macros are not importable into Swift. Values checked by
    // compiling against the system header (TIOCMGET = _IOR('t', 106, int), TIOCMSET = _IOW('t', 109, int)).
    private static let tiocmget: UInt = 0x4004_746A
    private static let tiocmset: UInt = 0x8004_746D
    private static let tiocmDTR: Int32 = 0x002
    private static let tiocmRTS: Int32 = 0x004

    public func setLines(dtr: Bool, rts: Bool) throws {
        guard !isClosedPort else { throw SerialError.closed }   // the fd number may already belong to something else
        var bits: Int32 = 0
        guard ioctl(fileDescriptor, Self.tiocmget, &bits) == 0 else { throw SerialError.writeFailed(errno) }
        if dtr { bits |= Self.tiocmDTR } else { bits &= ~Self.tiocmDTR }
        if rts { bits |= Self.tiocmRTS } else { bits &= ~Self.tiocmRTS }
        guard ioctl(fileDescriptor, Self.tiocmset, &bits) == 0 else { throw SerialError.writeFailed(errno) }
    }

    public func setBaudRate(_ baud: Int) throws {
        guard !isClosedPort else { throw SerialError.closed }
        var t = termios()
        guard tcgetattr(fileDescriptor, &t) == 0 else { throw SerialError.writeFailed(errno) }
        cfsetspeed(&t, speed_t(baud))
        guard tcsetattr(fileDescriptor, TCSANOW, &t) == 0 else { throw SerialError.writeFailed(errno) }
    }
}

/// Sequences of modem-line states that reset an ESP into its serial bootloader. DTR is wired
/// to GPIO0 and RTS to EN on the common auto-reset circuit; the pairs below are (DTR, RTS).
public enum ESPResetStrategy: Sendable {
    case tight(delay: Double)
    case classic(delay: Double)
    case usbJTAGSerial

    func run(on port: ESPSerial) async throws {
        func step(_ dtr: Bool, _ rts: Bool, wait: Double = 0) async throws {
            try port.setLines(dtr: dtr, rts: rts)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
        switch self {
        case .tight(let delay):
            try await step(false, false)
            try await step(true, true)
            try await step(false, true, wait: 0.1)       // IO0 high, EN low: in reset
            try await step(true, false, wait: delay)     // IO0 low, EN high: out of reset into the bootloader
            try await step(false, false)
        case .classic(let delay):
            try await step(false, false)
            try await step(false, true, wait: 0.1)
            try await step(true, false, wait: delay)
            try await step(false, false)
        case .usbJTAGSerial:
            try await step(false, false, wait: 0.1)
            try await step(true, false, wait: 0.1)
            try await step(true, true)                   // pass through (1,1) rather than (0,0)
            try await step(false, true, wait: 0.1)
            try await step(false, false)
        }
    }

    /// Order to try on connect. Native-USB boards enumerate as `usbmodem`; UART bridges as `usbserial`.
    public static func sequence(forPortPath path: String) -> [ESPResetStrategy] {
        let uart: [ESPResetStrategy] = [.tight(delay: 0.05), .tight(delay: 0.55), .classic(delay: 0.05), .classic(delay: 0.55)]
        return path.contains("usbmodem") ? [.usbJTAGSerial] + uart : uart + [.usbJTAGSerial]
    }

    static func hardReset(on port: ESPSerial, usb: Bool) async throws {
        try port.setLines(dtr: false, rts: true)
        try await Task.sleep(for: .seconds(usb ? 0.2 : 0.1))
        try port.setLines(dtr: false, rts: false)
        if usb { try await Task.sleep(for: .seconds(0.2)) }
    }
}
