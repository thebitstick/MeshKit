import CryptoKit
import Foundation

enum ESPOp {
    static let flashBegin: UInt8 = 0x02, flashData: UInt8 = 0x03, flashEnd: UInt8 = 0x04
    static let memBegin: UInt8 = 0x05, memEnd: UInt8 = 0x06, memData: UInt8 = 0x07
    static let sync: UInt8 = 0x08, writeReg: UInt8 = 0x09, readReg: UInt8 = 0x0A
    static let spiSetParams: UInt8 = 0x0B, spiAttach: UInt8 = 0x0D, changeBaud: UInt8 = 0x0F
    static let flashDeflBegin: UInt8 = 0x10, flashDeflData: UInt8 = 0x11, flashDeflEnd: UInt8 = 0x12
    static let spiFlashMD5: UInt8 = 0x13, getSecurityInfo: UInt8 = 0x14
    static let eraseFlash: UInt8 = 0xD0, eraseRegion: UInt8 = 0xD1, readFlash: UInt8 = 0xD2
}

/// Native implementation of the ESP serial bootloader protocol (ROM loader and flasher stub).
///
/// Packets are SLIP-framed. A request is `00 op len16 checksum32 data`; a response is
/// `01 op len16 value32 data`, where the data ends with a status byte and an error byte
/// (the ROM appends two more reserved bytes). Calls must be made one at a time.
public actor ESPLoader {
    public struct Reply: Sendable {
        public let value: UInt32
        public let data: [UInt8]
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<[UInt8], Error>
        var timeout: Task<Void, Never>?
    }

    public nonisolated let logger: (@Sendable (String) -> Void)?
    private let port: ESPSerial
    public private(set) var chip: ESPChip?
    public private(set) var isStub = false
    public private(set) var baudRate: Int
    private var usedUSBReset = false

    private var decoder = SLIPDecoder()
    private var packets: [[UInt8]] = []
    private var waiter: Waiter?
    private var nextWaiterID: UInt64 = 0
    private var readTask: Task<Void, Never>?
    private var rawLog: [UInt8] = []

    private static let romWriteBlock = 0x400
    private static let stubWriteBlock = 0x4000
    private static let ramBlock = 0x1800
    private static let checksumSeed: UInt8 = 0xEF

    public init(port: ESPSerial, baudRate: Int = 115_200, logger: (@Sendable (String) -> Void)? = nil) {
        self.port = port
        self.baudRate = baudRate
        self.logger = logger
    }

    public func start() {
        guard readTask == nil else { return }
        let stream = port.subscribe()
        readTask = Task { [weak self] in
            for await chunk in stream { await self?.ingest(chunk) }
            await self?.streamEnded()
        }
    }

    public func stop() {
        readTask?.cancel()
        readTask = nil
        failWaiter(ESPError.invalidResponse("connection closed"))
    }

    private var flashWriteSize: Int { isStub ? Self.stubWriteBlock : Self.romWriteBlock }

    // MARK: - Packet plumbing

    private func ingest(_ data: Data) {
        rawLog.append(contentsOf: data)
        if rawLog.count > 8192 { rawLog.removeFirst(rawLog.count - 8192) }
        for packet in decoder.feed(data) {
            if let w = waiter {
                waiter = nil
                w.timeout?.cancel()
                w.continuation.resume(returning: packet)
            } else {
                packets.append(packet)
            }
        }
    }

    private func streamEnded() { failWaiter(ESPError.invalidResponse("connection closed")) }

    private func failWaiter(_ error: Error, id: UInt64? = nil) {
        guard let w = waiter, id == nil || w.id == id else { return }
        waiter = nil
        w.timeout?.cancel()
        w.continuation.resume(throwing: error)
    }

    func flushInput() {
        packets.removeAll()
        decoder.reset()
    }

    private func nextPacket(timeout: Double, what: String) async throws -> [UInt8] {
        if !packets.isEmpty { return packets.removeFirst() }
        nextWaiterID += 1
        let id = nextWaiterID
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            let timer = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self.failWaiter(ESPError.timeout(what), id: id)
            }
            waiter = Waiter(id: id, continuation: cont, timeout: timer)
        }
    }

    private func send(_ packet: [UInt8]) async throws {
        try await port.send(SLIP.encode(packet))
    }

    static func checksum(_ data: [UInt8]) -> UInt32 {
        UInt32(data.reduce(checksumSeed, ^))
    }

    func command(
        _ op: UInt8, _ data: [UInt8] = [], checksum: UInt32 = 0, timeout: Double = 3, what: String? = nil
    ) async throws -> Reply {
        var packet: [UInt8] = [0x00, op]
        packet.appendLE(UInt16(data.count))
        packet.appendLE(checksum)
        packet += data
        try await send(packet)

        for _ in 0..<100 {
            let p = try await nextPacket(timeout: timeout, what: what ?? String(format: "command 0x%02X", op))
            guard p.count >= 8, p[0] == 0x01 else { continue }
            var r = ByteReader(Array(p[4..<8]))
            let value = try r.u32()
            let body = Array(p[8...])
            if p[1] == op { return Reply(value: value, data: body) }
            // The ROM answers an unknown command with an "invalid message" status (error 0x05),
            // sometimes several times over.
            if body.count >= 2, body[0] != 0, body[1] == 0x05 {
                try? await Task.sleep(for: .milliseconds(200))
                flushInput()
                throw ESPError.unsupportedCommand(what ?? String(format: "command 0x%02X", op))
            }
        }
        throw ESPError.invalidResponse("no reply matching command 0x\(String(op, radix: 16))")
    }

    @discardableResult
    func checkCommand(
        _ what: String, _ op: UInt8, _ data: [UInt8] = [], respDataLen: Int = 0, checksum: UInt32 = 0, timeout: Double = 3
    ) async throws -> Reply {
        let reply = try await command(op, data, checksum: checksum, timeout: timeout, what: what)
        let d = reply.data
        if d.count < respDataLen + 2 {
            if let s = d.first, s != 0 {
                throw ESPError.status(operation: what, code: UInt16(s) << 8 | UInt16(d.count > 1 ? d[1] : 0))
            }
            throw ESPError.invalidResponse("only \(d.count) bytes of status for \(what)")
        }
        let status = d[respDataLen], error = d[respDataLen + 1]
        if status != 0 { throw ESPError.status(operation: what, code: UInt16(status) << 8 | UInt16(error)) }
        return Reply(value: reply.value, data: Array(d[..<respDataLen]))
    }

    // MARK: - Connecting

    func sync() async throws {
        var payload: [UInt8] = [0x07, 0x07, 0x12, 0x20]
        payload += [UInt8](repeating: 0x55, count: 32)
        _ = try await command(ESPOp.sync, payload, timeout: 0.1, what: "sync")
        // The ROM answers a sync with several identical replies; swallow the rest.
        for _ in 0..<7 { _ = try? await nextPacket(timeout: 0.05, what: "sync reply") }
    }

    public func connect(strategies: [ESPResetStrategy], attempts: Int = 7) async throws {
        guard !strategies.isEmpty else { throw ESPError.noSync("No reset strategy was given.") }
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let strategy = strategies[attempt % strategies.count]
            if case .usbJTAGSerial = strategy { usedUSBReset = true } else { usedUSBReset = false }
            flushInput()
            rawLog.removeAll()
            do { try await strategy.run(on: port) } catch {
                logger?("reset failed: \(error.localizedDescription)")
            }
            for _ in 0..<5 {
                flushInput()
                do {
                    try await sync()
                    logger?("synced (attempt \(attempt + 1))")
                    return
                } catch {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        throw ESPError.noSync(bootModeHint())
    }

    private func bootModeHint() -> String {
        let text = String(decoding: rawLog, as: UTF8.self)
        if text.contains("waiting for download") {
            return "The chip is in download mode but isn't answering; check the TX line and try another cable."
        }
        if let range = text.range(of: #"boot:0x[0-9a-fA-F]+"#, options: .regularExpression) {
            return "The chip started normally (\(text[range])). Hold BOOT while pressing RESET, then try again."
        }
        return "No response from the chip. Check the cable and port, or hold BOOT while pressing RESET."
    }

    // MARK: - Chip detection

    public func readRegister(_ address: UInt32) async throws -> UInt32 {
        try await checkCommand("read register", ESPOp.readReg, withLE(address)).value
    }

    public func writeRegister(_ address: UInt32, _ value: UInt32, mask: UInt32 = 0xFFFF_FFFF, delayMicros: UInt32 = 0) async throws {
        var d: [UInt8] = []
        d.appendLE(address); d.appendLE(value); d.appendLE(mask); d.appendLE(delayMicros)
        try await checkCommand("write register", ESPOp.writeReg, d)
    }

    private func withLE(_ v: UInt32) -> [UInt8] { var d: [UInt8] = []; d.appendLE(v); return d }

    /// Security info reply: u32 flags, u8 flash_crypt_cnt, 7 key purposes, then (all but ESP32-S2) u32 chip id and u32 api version.
    func securityInfoChipID() async throws -> UInt16? {
        do {
            let r = try await checkCommand("get security info", ESPOp.getSecurityInfo, respDataLen: 20)
            var reader = ByteReader(r.data)
            _ = try reader.take(12, "flags")
            return UInt16(truncatingIfNeeded: try reader.u32("chip id"))
        } catch let e as ESPError {
            if case .unsupportedCommand = e { throw e }
            // ESP32-S2 answers with a shorter reply that has no chip ID.
            _ = try await checkCommand("get security info", ESPOp.getSecurityInfo, respDataLen: 12)
            return nil
        }
    }

    @discardableResult
    public func detectChip() async throws -> ESPChip {
        var detected: ESPChip?
        do {
            if let id = try await securityInfoChipID() {
                guard let c = ESPChip.fromChipID(id) else { throw ESPError.unsupportedChip("chip ID \(id)") }
                detected = c
            }
        } catch let e as ESPError {
            if case .unsupportedChip = e { throw e }
            // ESP32 (and ESP8266) ROMs don't implement the command; fall through to the magic value.
        }
        if detected == nil {
            let magic = try await readRegister(ESPChip.magicRegisterAddress)
            guard let c = ESPChip.fromMagic(magic) else {
                throw ESPError.unsupportedChip(String(format: "magic value 0x%08X", magic))
            }
            detected = c
        }
        chip = detected
        logger?("chip: \(detected!.rawValue)")
        return detected!
    }

    // MARK: - Flash setup

    /// Runs an SPI flash command through the controller's user-command registers (RDID only: no address, no write data).
    private func spiReadID() async throws -> UInt32 {
        guard let chip else { throw ESPError.unsupportedChip("not detected yet") }
        let s = chip.spi
        let base = s.base
        let usrCommand: UInt32 = 1 << 31, usrMISO: UInt32 = 1 << 28, cmdUsr: UInt32 = 1 << 18
        let readBits: UInt32 = 24

        let oldUsr = try await readRegister(base + s.usr)
        let oldUsr2 = try await readRegister(base + s.usr2)
        try await writeRegister(base + s.misoDLen, readBits - 1)
        try await writeRegister(base + s.usr, usrCommand | usrMISO)
        try await writeRegister(base + s.usr2, (7 << 28) | 0x9F)
        try await writeRegister(base + s.w0, 0)
        try await writeRegister(s.cmd, cmdUsr)
        var done = false
        for _ in 0..<10 where !done {
            done = (try await readRegister(s.cmd) & cmdUsr) == 0
        }
        guard done else { throw ESPError.timeout("SPI command") }
        let id = try await readRegister(base + s.w0)
        try await writeRegister(base + s.usr, oldUsr)
        try await writeRegister(base + s.usr2, oldUsr2)
        return id
    }

    public func detectFlash() async throws -> ESPFlashID {
        ESPFlashID(raw: try await spiReadID() & 0x00FF_FFFF)
    }

    /// The ROM loader needs the SPI flash pins attached explicitly on everything but classic ESP32. The stub does it itself.
    public func attachFlash() async throws {
        guard let chip, !isStub, chip != .esp32 else { return }
        var d: [UInt8] = []
        d.appendLE(UInt32(0))          // default pins
        d += [0, 0, 0, 0]              // "is legacy" flag and reserved bytes (ROM only)
        try await checkCommand("attach SPI flash", ESPOp.spiAttach, d)
    }

    public func setFlashParameters(size: Int) async throws {
        var d: [UInt8] = []
        d.appendLE(UInt32(0))                 // flash id
        d.appendLE(UInt32(size))              // total size
        d.appendLE(UInt32(64 * 1024))         // block size
        d.appendLE(UInt32(4 * 1024))          // sector size
        d.appendLE(UInt32(256))               // page size
        d.appendLE(UInt32(0xFFFF))            // status mask
        try await checkCommand("set SPI parameters", ESPOp.spiSetParams, d)
    }

    // MARK: - Stub

    private func memBegin(size: Int, blocks: Int, blockSize: Int, offset: UInt32) async throws {
        var d: [UInt8] = []
        d.appendLE(UInt32(size)); d.appendLE(UInt32(blocks)); d.appendLE(UInt32(blockSize)); d.appendLE(offset)
        try await checkCommand("enter RAM download mode", ESPOp.memBegin, d)
    }

    private func memBlock(_ block: [UInt8], seq: Int) async throws {
        var d: [UInt8] = []
        d.appendLE(UInt32(block.count)); d.appendLE(UInt32(seq)); d.appendLE(UInt32(0)); d.appendLE(UInt32(0))
        d += block
        try await checkCommand("write to RAM", ESPOp.memData, d, checksum: Self.checksum(block))
    }

    private func uploadSegment(_ bytes: [UInt8], at offset: UInt32) async throws {
        let blocks = (bytes.count + Self.ramBlock - 1) / Self.ramBlock
        try await memBegin(size: bytes.count, blocks: blocks, blockSize: Self.ramBlock, offset: offset)
        for seq in 0..<blocks {
            let from = seq * Self.ramBlock
            try await memBlock(Array(bytes[from..<min(from + Self.ramBlock, bytes.count)]), seq: seq)
        }
    }

    public func runStub() async throws {
        guard let chip else { throw ESPError.unsupportedChip("not detected yet") }
        guard !isStub else { return }
        let stub = try ESPStubImage.load(for: chip)
        logger?("uploading stub (\(stub.text.count + (stub.data?.count ?? 0)) bytes)")
        try await uploadSegment(stub.text, at: stub.textStart)
        if let data = stub.data, let start = stub.dataStart { try await uploadSegment(data, at: start) }

        var d: [UInt8] = []
        d.appendLE(UInt32(stub.entry == 0 ? 1 : 0)); d.appendLE(stub.entry)
        // The ROM may start running the stub before it manages to acknowledge MEM_END.
        _ = try? await checkCommand("start stub", ESPOp.memEnd, d, timeout: 0.5)

        let hello = Array("OHAI".utf8)
        for _ in 0..<4 {
            let p = try await nextPacket(timeout: 3, what: "stub greeting")
            if p == hello { isStub = true; logger?("stub running"); return }
        }
        throw ESPError.stubFailed("no greeting after start")
    }

    public func changeBaudRate(_ baud: Int) async throws {
        var d: [UInt8] = []
        d.appendLE(UInt32(baud))
        d.appendLE(UInt32(isStub ? baudRate : 0))
        _ = try await command(ESPOp.changeBaud, d, what: "change baud rate")
        try port.setBaudRate(baud)
        baudRate = baud
        try? await Task.sleep(for: .milliseconds(50))
        flushInput()
        logger?("baud \(baud)")
    }

    // MARK: - Writing

    private func md5Hex(_ bytes: [UInt8]) -> String {
        Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Pads to a 4-byte multiple, and without the stub (which erases whole sectors only) pads the front so the write starts on a sector boundary.
    static func prepare(_ image: [UInt8], at address: UInt32, stub: Bool) -> (start: UInt32, data: [UInt8]) {
        var data = image
        while data.count % 4 != 0 { data.append(0xFF) }
        var start = address
        if !stub {
            let over = Int(start % 0x1000)
            start -= UInt32(over)
            data = [UInt8](repeating: 0xFF, count: over) + data
        }
        return (start, data)
    }

    public func verifyFlash(_ image: [UInt8], at address: UInt32) async throws {
        let (start, data) = Self.prepare(image, at: address, stub: isStub)
        let expected = md5Hex(data)
        let actual = try await flashMD5(address: start, size: data.count)
        if actual != expected { throw ESPError.verifyFailed(expected: expected, actual: actual) }
    }

    public func writeFlash(
        _ image: [UInt8], at address: UInt32, compress: Bool = true, verify: Bool = true,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard !image.isEmpty else { throw ESPError.emptyImage }
        let (start, data) = Self.prepare(image, at: address, stub: isStub)
        let digest = md5Hex(data)
        let uncompressedSize = data.count

        var payload = data
        var compressed = false
        if compress, let z = ZLib.compress(data), z.count < data.count { payload = z; compressed = true }
        logger?("writing \(uncompressedSize) bytes at 0x\(String(start, radix: 16)) (\(compressed ? "compressed to \(payload.count)" : "uncompressed"))")

        let block = flashWriteSize
        let blocks = (payload.count + block - 1) / block
        let eraseBlocks = (uncompressedSize + block - 1) / block
        let romEraseTimeout = max(3, 40 * Double(uncompressedSize) / 1e6)

        guard let chip else { throw ESPError.unsupportedChip("not detected yet") }
        var begin: [UInt8] = []
        if compressed {
            begin.appendLE(UInt32(isStub ? uncompressedSize : eraseBlocks * block))
            begin.appendLE(UInt32(blocks)); begin.appendLE(UInt32(block)); begin.appendLE(start)
        } else {
            begin.appendLE(UInt32(uncompressedSize))
            begin.appendLE(UInt32((uncompressedSize + block - 1) / block)); begin.appendLE(UInt32(block)); begin.appendLE(start)
        }
        if isStub || chip.romFlashBeginHasEncryptedFlag { begin.appendLE(UInt32(0)) }
        try await checkCommand(compressed ? "enter compressed flash mode" : "enter flash mode",
                               compressed ? ESPOp.flashDeflBegin : ESPOp.flashBegin, begin,
                               timeout: isStub ? 3 : romEraseTimeout)

        let totalBlocks = compressed ? blocks : (uncompressedSize + block - 1) / block
        let source = compressed ? payload : data
        // ROM blocks decompress and write synchronously, so a compressed block can take a while.
        let blockTimeout: Double = isStub ? 3 : 15
        for seq in 0..<totalBlocks {
            try Task.checkCancellation()
            var chunk = Array(source[(seq * block)..<min((seq + 1) * block, source.count)])
            if !compressed, chunk.count < block { chunk += [UInt8](repeating: 0xFF, count: block - chunk.count) }
            var d: [UInt8] = []
            d.appendLE(UInt32(chunk.count)); d.appendLE(UInt32(seq)); d.appendLE(UInt32(0)); d.appendLE(UInt32(0))
            d += chunk
            try await withRetries(3) {
                try await self.checkCommand("write flash block \(seq)", compressed ? ESPOp.flashDeflData : ESPOp.flashData, d,
                                            checksum: Self.checksum(chunk), timeout: blockTimeout)
            }
            progress?(Double(seq + 1) / Double(totalBlocks))
        }

        if isStub {
            // The stub acknowledges blocks as it receives them; ending the transfer waits until the last one is on flash.
            var end: [UInt8] = []
            end.appendLE(UInt32(1))   // stay in the stub rather than rebooting
            try await checkCommand("finish flash write", compressed ? ESPOp.flashDeflEnd : ESPOp.flashEnd, end, timeout: 30)
        }

        if verify {
            let actual = try await flashMD5(address: start, size: uncompressedSize)
            if actual != digest { throw ESPError.verifyFailed(expected: digest, actual: actual) }
        }
    }

    private func withRetries(_ attempts: Int, _ body: () async throws -> Void) async throws {
        var last: Error?
        for _ in 0..<attempts {
            do { try await body(); return } catch let e as ESPError {
                switch e {
                case .status, .timeout: last = e
                default: throw e
                }
            }
        }
        throw last ?? ESPError.invalidResponse("write failed")
    }

    public func flashMD5(address: UInt32, size: Int) async throws -> String {
        var d: [UInt8] = []
        d.appendLE(address); d.appendLE(UInt32(size)); d.appendLE(UInt32(0)); d.appendLE(UInt32(0))
        let timeout = max(3, 8 * Double(size) / 1e6)
        // The ROM answers with 32 ASCII hex characters, the stub with 16 raw bytes.
        let r = try await checkCommand("calculate MD5", ESPOp.spiFlashMD5, d, respDataLen: isStub ? 16 : 32, timeout: timeout)
        return isStub ? r.data.map { String(format: "%02x", $0) }.joined() : String(decoding: r.data, as: UTF8.self)
    }

    // MARK: - Reading and erasing (stub only)

    public func eraseFlash() async throws {
        guard isStub else { throw ESPError.notInStubMode("Erasing the whole flash") }
        try await checkCommand("erase flash", ESPOp.eraseFlash, timeout: 120)
    }

    /// Reads flash contents. Each block is acknowledged back to the stub, and the stub finishes with an MD5 of what it sent.
    public func readFlash(offset: UInt32, length: Int, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [UInt8] {
        guard isStub else { throw ESPError.notInStubMode("Reading flash") }
        let sector = 0x1000
        var d: [UInt8] = []
        d.appendLE(offset); d.appendLE(UInt32(length)); d.appendLE(UInt32(sector)); d.appendLE(UInt32(64))
        try await checkCommand("read flash", ESPOp.readFlash, d)

        var data: [UInt8] = []
        data.reserveCapacity(length)
        while data.count < length {
            try Task.checkCancellation()
            let p = try await nextPacket(timeout: 5, what: "flash data")
            data += p
            if data.count < length, p.count < sector {
                throw ESPError.readCorrupt("expected \(sector) bytes in a block, got \(p.count)")
            }
            var ack: [UInt8] = []
            ack.appendLE(UInt32(data.count))
            try await send(ack)
            progress?(Double(min(data.count, length)) / Double(length))
        }
        guard data.count == length else { throw ESPError.readCorrupt("received \(data.count) of \(length) bytes") }
        let digest = try await nextPacket(timeout: 5, what: "flash digest")
        guard digest.count == 16 else { throw ESPError.readCorrupt("missing digest") }
        let expected = digest.map { String(format: "%02x", $0) }.joined()
        let actual = md5Hex(data)
        guard expected == actual else { throw ESPError.readCorrupt("digest mismatch (\(expected.prefix(8)) vs \(actual.prefix(8)))") }
        return data
    }

    // MARK: - Leaving

    public func hardReset() async throws {
        try await ESPResetStrategy.hardReset(on: port, usb: usedUSBReset)
    }
}
