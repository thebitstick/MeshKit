import Foundation

public struct NRF52DFUPackage: Sendable {
    public let initPacket: Data
    public let firmware: Data

    public init(initPacket: Data, firmware: Data) {
        self.initPacket = initPacket; self.firmware = firmware
    }

    public enum PackageError: LocalizedError {
        case notAnApplicationPackage
        public var errorDescription: String? {
            "This firmware package has no application in it. MeshKit can only install application packages over USB."
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
    private let bootloaderDrives: @Sendable () -> [UF2Volume]

    /// `waitScale` shortens the flash-timing waits; only simulators should change it.
    public init(portPath: String, package: NRF52DFUPackage, waitScale: Double = 1,
                touchPort: (@Sendable () async throws -> Void)? = nil, openPort: (@Sendable () async throws -> ByteTransport)? = nil,
                bootloaderDrives: @escaping @Sendable () -> [UF2Volume] = { UF2Volumes.detect() },
                logger: (@Sendable (String) -> Void)? = nil) {
        self.portPath = portPath; self.package = package; self.waitScale = waitScale
        self.touchPort = touchPort; self.openPort = openPort; self.bootloaderDrives = bootloaderDrives; self.logger = logger
    }

    public var steps: [FlashStep] {
        [.init(id: "touch", title: "Restart the board in update mode"),
         .init(id: "connect", title: "Connect to the board"),
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

        // The board can re-enumerate on USB just after it enters the bootloader (the port then closes under us), so a session
        // that loses its port or its acknowledgements is started again from the top a couple of times before giving up.
        var lastError: Error = DFUError.noAcknowledgement
        for attempt in 1...3 {
            do {
                try await session(update: update, firstAttempt: attempt == 1)
                return
            } catch SerialError.closed {
                lastError = SerialError.closed
            } catch SerialError.writeFailed(let code) {
                lastError = SerialError.writeFailed(code)
            } catch DFUError.noAcknowledgement {
                lastError = DFUError.noAcknowledgement
            }
            logger?("the DFU session was interrupted (attempt \(attempt) of 3); starting it again")
            try await sleep(2)
        }
        throw lastError
    }

    private func session(update: @escaping @Sendable (String, FlashStep.State) -> Void, firstAttempt: Bool) async throws {
        update("connect", .running(nil))
        let transport: ByteTransport
        if let openPort { transport = try await openPort() } else if firstAttempt { transport = try await openBootloaderPort() } else { transport = try await openAnyPort() }
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
        case noAcknowledgement, portMissing(String), wipeTimedOut
        public var errorDescription: String? {
            switch self {
            case .noAcknowledgement: "The bootloader stopped answering. Unplug the board, double-tap reset to get its drive, and install from there."
            case .portMissing(let p): "The serial port \(p) did not come back after restarting the board."
            case .wipeTimedOut: "The erase tool didn't finish wiping the board. Unplug it, double-tap reset to get its drive, and do the clean install from there."
            }
        }
    }

    private func touch() async throws {
        // A board that already shows its bootloader drive is in the bootloader, whose serial port speaks DFU as it is.
        // The 1200-baud touch would only restart it and change its port.
        if !bootloaderDrives().isEmpty { logger?("the board is already in its bootloader; not restarting it"); return }
        try await NRF52DFUMode.touch(path: portPath)
        logger?("touched \(portPath) at 1200 baud")
        try await sleep(1.5)
    }

    /// The bootloader's serial port. macOS often numbers it differently from the application's (`usbmodem1101` becoming
    /// `usbmodem2101`), so when the old name doesn't come back the only USB modem port that has appeared is used.
    private func openAnyPort() async throws -> ByteTransport {
        for _ in 0..<40 {
            if let path = NRF52SerialCleanFlasher.usbModemPorts().first, let port = try? SerialPort(path: path) {
                try await Task.sleep(for: .milliseconds(300))
                return port
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DFUError.portMissing(portPath)
    }

    private func openBootloaderPort() async throws -> ByteTransport {
        for attempt in 0..<48 {
            var path: String?
            if FileManager.default.fileExists(atPath: portPath) { path = portPath }
            else if attempt >= 8 { path = NRF52SerialCleanFlasher.usbModemPorts().first }
            if let path, let port = try? SerialPort(path: path) {
                if path != portPath { logger?("the bootloader's port is \(path), not \(portPath)") }
                try await Task.sleep(for: .milliseconds(300))
                return port
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DFUError.portMissing(portPath)
    }
}

/// A clean install without a bootloader drive: Meshtastic's erase tool goes in over serial DFU as if it were the
/// firmware, wipes the board when a host opens its serial port and drops the board back into the bootloader, and then the
/// real firmware goes in over serial DFU as usual.
public struct NRF52SerialCleanFlasher: Flasher {
    public let portPath: String
    public let eraser: NRF52DFUPackage
    public let package: NRF52DFUPackage
    private let logger: (@Sendable (String) -> Void)?
    private let waitScale: Double
    private let touchPort: (@Sendable () async throws -> Void)?
    private let openPorts: [@Sendable () async throws -> ByteTransport]
    private let wipeBoard: @Sendable () async throws -> Void

    /// `openPorts` and `touchPort` stand in for the real serial port, one transport per DFU session, for simulators.
    public init(portPath: String, eraser: NRF52DFUPackage, package: NRF52DFUPackage, waitScale: Double = 1,
                touchPort: (@Sendable () async throws -> Void)? = nil,
                openPorts: [@Sendable () async throws -> ByteTransport] = [],
                wipeBoard: (@Sendable () async throws -> Void)? = nil,
                logger: (@Sendable (String) -> Void)? = nil) {
        self.portPath = portPath; self.eraser = eraser; self.package = package; self.waitScale = waitScale
        self.touchPort = touchPort; self.openPorts = openPorts; self.logger = logger
        self.wipeBoard = wipeBoard ?? { try await Self.wipeThroughSerial(timeout: .seconds(120 * waitScale), logger: logger) }
    }

    public var steps: [FlashStep] {
        [.init(id: "touch", title: "Restart the board in update mode"),
         .init(id: "tool", title: "Load the erase tool"),
         .init(id: "wipe", title: "Wipe the board"),
         .init(id: "write", title: "Send the firmware"),
         .init(id: "activate", title: "Activate the new firmware")]
    }

    public func run(update: @escaping @Sendable (String, FlashStep.State) -> Void) async throws {
        let first = NRF52SerialDFUFlasher(portPath: portPath, package: eraser, waitScale: waitScale, touchPort: touchPort,
                                          openPort: openPorts.first, logger: logger)
        try await first.run { id, state in
            switch id {
            case "touch": update("touch", state)
            case "write": update("tool", state)
            case "connect", "erase": update("tool", .running(nil))
            default: break
            }
        }
        update("tool", .done)

        update("wipe", .running(nil))
        try await wipeBoard()
        update("wipe", .done)

        let second = NRF52SerialDFUFlasher(portPath: portPath, package: package, waitScale: waitScale, touchPort: {},
                                           openPort: openPorts.dropFirst().first ?? { try await Self.openAnyBootloaderPort() }, logger: logger)
        try await second.run { id, state in
            switch id {
            case "connect", "erase": update("write", .running(nil))
            case "write", "activate": update(id, state)
            default: break
            }
        }
    }

    public static func usbModemPorts() -> [String] { SerialDiscovery.list().map(\.path).filter { $0.contains("usbmodem") } }

    /// The erase tool does nothing until a host opens its serial port, then wipes the flash and reboots into the
    /// bootloader. So the port is opened as soon as it shows up; the board has finished when that port goes away and a
    /// port (the bootloader's) comes back.
    static func wipeThroughSerial(timeout: Duration, logger: (@Sendable (String) -> Void)?,
                                  volumes: @Sendable () -> [UF2Volume] = { UF2Volumes.detect() },
                                  ports: @Sendable () -> [String] = { usbModemPorts() }) async throws {
        let deadline = ContinuousClock.now + timeout
        var vanished = false
        // A bootloader drive may already be mounted when the erase tool is loaded. It goes away while the tool runs, and
        // coming back is what says the board has been wiped and restarted into its bootloader. A drive that was there at
        // the start (this board's, or another board's) only counts once it has been seen gone and back; a different one
        // that appears counts at once.
        let atStart = Set(volumes().map(\.id))
        var goneSinceStart = Set<String>()
        func driveBack() -> Bool {
            let present = Set(volumes().map(\.id))
            goneSinceStart.formUnion(atStart.subtracting(present))
            return present.contains { !atStart.contains($0) || goneSinceStart.contains($0) }
        }
        while ContinuousClock.now < deadline {
            if driveBack() { logger?("the bootloader's drive is back"); try await Task.sleep(for: .seconds(3)); return }
            guard let path = ports().first else { try await Task.sleep(for: .milliseconds(500)); continue }
            if vanished { try await Task.sleep(for: .seconds(3)); return }
            guard let port = try? SerialPort(path: path) else { try await Task.sleep(for: .milliseconds(500)); continue }
            logger?("opened \(path) for the erase tool")
            let holdUntil = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < holdUntil {
                if !FileManager.default.fileExists(atPath: path) { vanished = true; break }
                if driveBack() { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            port.close()
            if vanished { logger?("the erase tool restarted the board"); try await Task.sleep(for: .seconds(1)) }
        }
        throw NRF52SerialDFUFlasher.DFUError.wipeTimedOut
    }

    static func openAnyBootloaderPort() async throws -> ByteTransport {
        for _ in 0..<80 {
            if let path = usbModemPorts().first, let port = try? SerialPort(path: path) {
                try await Task.sleep(for: .milliseconds(300))
                return port
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NRF52SerialDFUFlasher.DFUError.portMissing("the bootloader's port")
    }
}
