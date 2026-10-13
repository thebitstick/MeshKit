import Foundation

public struct NRF52DFUPackage: Sendable {
    public let initPacket: Data
    public let firmware: Data

    public enum PackageError: LocalizedError {
        case notAnApplicationPackage
        public var errorDescription: String? {
            "This DFU package doesn't contain an application image. MeshKit only installs application packages over serial DFU."
        }
    }

    /// Reads a Nordic DFU `.zip`: `manifest.json` names the init packet (`.dat`) and the application image (`.bin`).
    public static func read(zip data: Data) async throws -> NRF52DFUPackage {
        let zip = RemoteZip(source: DataRangeSource(data))
        let manifest = try JSONSerialization.jsonObject(with: try await zip.read("manifest.json")) as? [String: Any]
        guard let app = (manifest?["manifest"] as? [String: Any])?["application"] as? [String: Any],
              let bin = app["bin_file"] as? String, let dat = app["dat_file"] as? String else { throw PackageError.notAnApplicationPackage }
        return NRF52DFUPackage(initPacket: try await zip.read(dat), firmware: try await zip.read(bin))
    }
}

/// The serial DFU protocol of the Adafruit nRF52 bootloader (Nordic's legacy "HCI over SLIP" transport), as spoken by
/// `adafruit-nrfutil`: every packet is a 4-byte header, a payload and a CRC-16, SLIP-encoded, and the device acknowledges it.
public enum NRF52HCI {
    static let packetType = 14
    static let initPacket: UInt32 = 1, startPacket: UInt32 = 3, dataPacket: UInt32 = 4, stopDataPacket: UInt32 = 5
    static let updateModeApplication: UInt32 = 4

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc = (crc >> 8 & 0x00FF) | (crc << 8 & 0xFF00)
            crc ^= UInt16(b)
            crc ^= (crc & 0x00FF) >> 4
            crc ^= crc << 12
            crc ^= (crc & 0x00FF) << 5
        }
        return crc
    }

    static func slipEncode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for b in bytes {
            switch b {
            case 0xC0: out += [0xDB, 0xDC]
            case 0xDB: out += [0xDB, 0xDD]
            default: out.append(b)
            }
        }
        return out
    }

    /// One framed packet. `sequence` runs 1...7 then 0, 1, … (the previous number plus one, modulo 8).
    static func packet(sequence: Int, payload: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 4)
        header[0] = UInt8(sequence | ((sequence + 1) % 8) << 3 | 1 << 6 | 1 << 7)
        header[1] = UInt8(packetType | (payload.count & 0x000F) << 4)
        header[2] = UInt8((payload.count & 0x0FF0) >> 4)
        header[3] = UInt8(truncatingIfNeeded: (~(Int(header[0]) + Int(header[1]) + Int(header[2]))) + 1)
        var body = header + payload
        let crc = crc16(body)
        body += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return [0xC0] + slipEncode(body) + [0xC0]
    }

    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// The acknowledgement number carried by a device frame (bits 3-5 of the first header byte).
    static func ackNumber(inFrame frame: [UInt8]) -> Int? {
        var decoded: [UInt8] = []
        var escaped = false
        for b in frame {
            if escaped { decoded.append(b == 0xDC ? 0xC0 : b == 0xDD ? 0xDB : b); escaped = false } else if b == 0xDB { escaped = true } else { decoded.append(b) }
        }
        guard let first = decoded.first else { return nil }
        return Int(first >> 3) & 0x07
    }
}

/// Collects serial bytes and splits them into `0xC0`-delimited frames.
private final class FrameReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var frames: [[UInt8]] = []
    private var task: Task<Void, Never>?

    init(transport: ByteTransport) {
        let stream = transport.subscribe()
        task = Task { [weak self] in
            for await chunk in stream { self?.feed([UInt8](chunk)) }
        }
    }

    deinit { task?.cancel() }

    private func feed(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        for b in bytes {
            if b == 0xC0 {
                if !buffer.isEmpty { frames.append(buffer); buffer = [] }
            } else {
                buffer.append(b)
            }
        }
    }

    func clear() { lock.lock(); frames = []; buffer = []; lock.unlock() }

    private func popFrame() -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return frames.isEmpty ? nil : frames.removeFirst()
    }

    func nextFrame(timeout: Duration) async -> [UInt8]? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let frame = popFrame() { return frame }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
}

public struct NRF52SerialDFUFlasher: Flasher {
    public let portPath: String
    public let package: NRF52DFUPackage
    private let logger: (@Sendable (String) -> Void)?
    private let waitScale: Double
    private let touchPort: (@Sendable () async throws -> Void)?
    private let openPort: (@Sendable () async throws -> ByteTransport)?

    /// `waitScale` shortens the flash-timing waits; only simulators should change it.
    public init(portPath: String, package: NRF52DFUPackage, waitScale: Double = 1,
                touchPort: (@Sendable () async throws -> Void)? = nil, openPort: (@Sendable () async throws -> ByteTransport)? = nil,
                logger: (@Sendable (String) -> Void)? = nil) {
        self.portPath = portPath; self.package = package; self.waitScale = waitScale
        self.touchPort = touchPort; self.openPort = openPort; self.logger = logger
    }

    public var steps: [FlashStep] {
        [.init(id: "touch", title: "Restart the board into serial DFU"),
         .init(id: "connect", title: "Connect to the bootloader"),
         .init(id: "erase", title: "Erase space for the new firmware"),
         .init(id: "write", title: "Send the firmware"),
         .init(id: "activate", title: "Activate the new firmware")]
    }

    static let pageSize = 4096
    static let pageEraseTime = 0.0897
    static let pageWriteTime = Double(pageSize / 4) * 0.0001
    static let chunk = 512

    private func sleep(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds * waitScale)) }

    public func run(update: @escaping @Sendable (String, FlashStep.State) -> Void) async throws {
        update("touch", .running(nil))
        if let touchPort { try await touchPort() } else { try await touch() }
        update("touch", .done)

        update("connect", .running(nil))
        let transport: ByteTransport
        if let openPort { transport = try await openPort() } else { transport = try await openBootloaderPort() }
        defer { transport.close() }
        let reader = FrameReader(transport: transport)
        var sequence = 0
        func send(_ payload: [UInt8]) async throws {
            sequence = (sequence + 1) % 8
            let bytes = NRF52HCI.packet(sequence: sequence, payload: payload)
            for attempt in 1...4 {
                reader.clear()
                try await transport.send(Data(bytes))
                if let frame = await reader.nextFrame(timeout: .seconds(1)), let ack = NRF52HCI.ackNumber(inFrame: frame) {
                    if ack == (sequence + 1) % 8 { return }
                    logger?("unexpected acknowledgement \(ack) for packet \(sequence) (attempt \(attempt))")
                } else {
                    logger?("no acknowledgement for packet \(sequence) (attempt \(attempt))")
                }
            }
            throw DFUError.noAcknowledgement
        }

        let app = package.firmware
        let size = UInt32(app.count)
        try await send(NRF52HCI.le32(NRF52HCI.startPacket) + NRF52HCI.le32(NRF52HCI.updateModeApplication) + NRF52HCI.le32(0) + NRF52HCI.le32(0) + NRF52HCI.le32(size))
        update("connect", .done)

        update("erase", .running(nil))
        let pages = app.count / Self.pageSize + 1
        let eraseWait = max(0.5, Double(pages) * Self.pageEraseTime)
        try await sleep(eraseWait)
        update("erase", .done)

        try await send(NRF52HCI.le32(NRF52HCI.initPacket) + [UInt8](package.initPacket) + [0, 0])

        update("write", .running(0))
        let bytes = [UInt8](app)
        var offset = 0, count = 0
        while offset < bytes.count {
            let end = min(offset + Self.chunk, bytes.count)
            try await send(NRF52HCI.le32(NRF52HCI.dataPacket) + Array(bytes[offset..<end]))
            offset = end
            if count % 8 == 0 { try await sleep(Self.pageWriteTime) }
            count += 1
            if count % 16 == 0 { update("write", .running(Double(offset) / Double(bytes.count))) }
        }
        try await sleep(Self.pageWriteTime)
        try await send(NRF52HCI.le32(NRF52HCI.stopDataPacket))
        update("write", .done)

        // The bootloader erases bank 0 and copies the image across. Closing the port too early resets the chip mid-copy.
        update("activate", .running(nil))
        try await sleep(eraseWait + Double(pages) * Self.pageWriteTime)
        update("activate", .done)
    }

    public enum DFUError: LocalizedError {
        case noAcknowledgement, portMissing(String)
        public var errorDescription: String? {
            switch self {
            case .noAcknowledgement: "The bootloader stopped answering. Unplug the board, double-tap reset to get its drive, and install from there."
            case .portMissing(let p): "The serial port \(p) did not come back after restarting the board."
            }
        }
    }

    private func touch() async throws {
        try await NRF52DFUMode.touch(path: portPath)
        logger?("touched \(portPath) at 1200 baud")
        try await sleep(1.5)
    }

    private func openBootloaderPort() async throws -> ByteTransport {
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: portPath), let port = try? SerialPort(path: portPath) {
                try await Task.sleep(for: .milliseconds(300))
                return port
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DFUError.portMissing(portPath)
    }
}
