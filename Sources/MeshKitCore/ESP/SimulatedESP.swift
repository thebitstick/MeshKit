import CryptoKit
import Foundation

public final class SimulatedESPDevice: ESPSerial, @unchecked Sendable {
    public struct LineState: Equatable, Sendable { public let dtr: Bool; public let rts: Bool }

    private let broadcaster = DataBroadcaster()
    private let lock = NSLock()
    private var decoder = SLIPDecoder()

    public let chip: ESPChip
    public let usbJTAG: Bool
    private let flashID: UInt32
    private var flash: [UInt8]

    private var inBootloader: Bool
    private var inStub = false
    private var dtr = false, rts = false
    private var io0LatchedLow = false          // USB-Serial-JTAG strap latch
    private var inReset = false
    private var lineLog: [LineState] = []
    private var baud = 115_200

    private var regs: [UInt32: UInt32] = [:]

    private struct WriteOp {
        var offset: Int; var blockSize: Int; var blocks: Int; var compressed: Bool
        var eraseSize: Int
        var received: [UInt8] = []
        var nextSeq = 0
    }
    private var writeOp: WriteOp?
    private var memEntry: UInt32?

    public struct LoggedCommand: Sendable { public let op: UInt8; public let data: [UInt8]; public let checksum: UInt32 }
    private var commandLog: [LoggedCommand] = []
    public var commands: [LoggedCommand] { lock.withLock { commandLog } }
    public func clearCommandLog() { lock.withLock { commandLog.removeAll() } }

    public var corruptChecksumOnce = false
    public var dropSyncReplies = false

    public init(chip: ESPChip = .esp32s3, flashSize: Int = 8 << 20, usbJTAG: Bool = false, startInBootloader: Bool = false) {
        self.chip = chip
        self.usbJTAG = usbJTAG
        self.flash = [UInt8](repeating: 0xFF, count: flashSize)
        // Winbond-style JEDEC ID: manufacturer 0xEF, type 0x40, capacity code from the size.
        let capacity: UInt32 = UInt32(Int(log2(Double(flashSize))))
        self.flashID = (capacity << 16) | (0x40 << 8) | 0xEF
        self.inBootloader = startInBootloader
    }

    // MARK: Inspection (for tests)

    public var flashContents: [UInt8] { lock.withLock { flash } }
    public var resetLog: [LineState] { lock.withLock { lineLog } }
    public var isInBootloader: Bool { lock.withLock { inBootloader } }
    public var isStubRunning: Bool { lock.withLock { inStub } }
    public var currentBaud: Int { lock.withLock { baud } }

    public func resetToROM() {
        lock.withLock { inBootloader = true; inStub = false; writeOp = nil; decoder.reset() }
    }

    public func preload(_ bytes: [UInt8], at offset: Int) {
        lock.withLock { flash.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
    }

    // MARK: ESPSerial

    public func subscribe() -> AsyncStream<Data> { broadcaster.subscribe() }
    public func close() { broadcaster.finish() }

    public func setBaudRate(_ baud: Int) throws { lock.withLock { self.baud = baud } }

    public func setLines(dtr newDTR: Bool, rts newRTS: Bool) throws {
        lock.withLock {
            lineLog.append(LineState(dtr: newDTR, rts: newRTS))
            if usbJTAG {
                // The USB-Serial-JTAG block decodes DTR/RTS pairs itself: (1,0) straps GPIO0 low,
                // (0,1) resets, and (0,0) releases reset into whichever mode the strap selects.
                switch (newDTR, newRTS) {
                case (true, false): io0LatchedLow = true
                case (false, true): inReset = true
                case (false, false):
                    if inReset { boot(download: io0LatchedLow); io0LatchedLow = false; inReset = false }
                default: break
                }
            } else {
                if newRTS { inReset = true }
                if rts, !newRTS, inReset {            // EN rising edge: sample GPIO0
                    boot(download: newDTR)
                    inReset = false
                }
                if newRTS, !rts { inBootloader = false; inStub = false }
            }
            dtr = newDTR; rts = newRTS
        }
    }

    private func boot(download: Bool) {
        inBootloader = download
        inStub = false
        writeOp = nil
        decoder.reset()
        if download {
            // The ROM prints a banner before it starts listening; real boards do this at 115200.
            broadcaster.yield(Data("ESP-ROM:simulated\r\nrst:0x1 (POWERON),boot:0x0 (DOWNLOAD(USB/UART0))\r\nwaiting for download\r\n".utf8))
        } else {
            broadcaster.yield(Data("rst:0x1 (POWERON),boot:0x8 (SPI_FAST_FLASH_BOOT)\r\n".utf8))
        }
    }

    public func send(_ data: Data) async throws {
        let outgoing: [[UInt8]] = lock.withLock {
            guard inBootloader else { return [] }
            return decoder.feed(data).flatMap { handle(packet: $0) }
        }
        for p in outgoing { broadcaster.yield(SLIP.encode(p)) }
    }

    // MARK: Protocol

    private func response(_ op: UInt8, value: UInt32 = 0, payload: [UInt8] = [], status: UInt8 = 0, error: UInt8 = 0) -> [UInt8] {
        var data = payload + [status, error]
        if !inStub { data += [0, 0] }       // ROM loaders append two reserved bytes after the status
        var out: [UInt8] = [0x01, op]
        out.appendLE(UInt16(data.count)); out.appendLE(value)
        return out + data
    }

    private func fail(_ op: UInt8, _ code: UInt8) -> [[UInt8]] { [response(op, status: 1, error: code)] }

    private func handle(packet: [UInt8]) -> [[UInt8]] {
        guard packet.count >= 8, packet[0] == 0x00 else { return [] }   // acks from the host are short; ignore them
        let op = packet[1]
        var hdr = ByteReader(Array(packet[2..<8]))
        let declared = Int((try? hdr.u16()) ?? 0)
        let checksum = (try? hdr.u32()) ?? 0
        let data = Array(packet[8...])
        guard data.count == declared else { return fail(op, 0x05) }
        commandLog.append(LoggedCommand(op: op, data: data, checksum: checksum))
        var r = ByteReader(data)

        switch op {
        case ESPOp.sync:
            if dropSyncReplies { return [] }
            let reply = response(op, value: inStub ? 0 : 0x0000_1234)
            return Array(repeating: reply, count: 8)

        case ESPOp.readReg:
            guard let addr = try? r.u32() else { return fail(op, 0x05) }
            return [response(op, value: readReg(addr))]

        case ESPOp.writeReg:
            guard let addr = try? r.u32(), let value = try? r.u32() else { return fail(op, 0x05) }
            writeReg(addr, value)
            return [response(op)]

        case ESPOp.getSecurityInfo:
            if chip == .esp32 { return fail(op, 0x05) }           // classic ESP32 ROM has no such command
            var info: [UInt8] = []
            info.appendLE(UInt32(0)); info += [UInt8](repeating: 0, count: 8)
            if chip != .esp32s2 { info.appendLE(UInt32(chip.imageChipID)); info.appendLE(UInt32(0)) }
            return [response(op, payload: info)]

        case ESPOp.spiAttach, ESPOp.spiSetParams:
            return [response(op)]

        case ESPOp.changeBaud:
            if let newBaud = try? r.u32() { baud = Int(newBaud) }
            return [response(op)]

        case ESPOp.memBegin, ESPOp.memData:
            return [response(op)]

        case ESPOp.memEnd:
            _ = try? r.u32()
            let entry = (try? r.u32()) ?? 0
            var out = [response(op)]
            if entry != 0, !inStub {
                inStub = true
                out.append(Array("OHAI".utf8))
            }
            return out

        case ESPOp.flashBegin, ESPOp.flashDeflBegin:
            guard let size = try? r.u32(), let blocks = try? r.u32(), let blockSize = try? r.u32(), let offset = try? r.u32() else {
                return fail(op, 0x05)
            }
            let compressed = op == ESPOp.flashDeflBegin
            guard Int(offset) + Int(size) <= flash.count else { return fail(op, 0x06) }
            // ROM erases up front; the stub erases as it writes. Either way the region ends up erased.
            if size > 0 { flash.replaceSubrange(Int(offset)..<Int(offset) + Int(size), with: repeatElement(0xFF, count: Int(size))) }
            writeOp = WriteOp(offset: Int(offset), blockSize: Int(blockSize), blocks: Int(blocks), compressed: compressed, eraseSize: Int(size))
            return [response(op)]

        case ESPOp.flashData, ESPOp.flashDeflData:
            guard var w = writeOp, let len = try? r.u32(), let seq = try? r.u32() else { return fail(op, 0x06) }
            _ = try? r.u32(); _ = try? r.u32()
            let body = r.rest()
            guard body.count == Int(len) else { return fail(op, 0x05) }
            var expected = UInt32(body.reduce(0xEF, ^))
            if corruptChecksumOnce { corruptChecksumOnce = false; expected ^= 1 }
            guard expected == checksum else { return fail(op, 0x07) }
            guard Int(seq) == w.nextSeq else { return fail(op, 0x06) }
            w.nextSeq += 1
            if w.compressed {
                w.received += body
                if w.nextSeq == w.blocks {
                    guard let plain = ZLib.inflate(w.received, capacity: w.eraseSize + 4096) else { writeOp = nil; return fail(op, 0x0B) }
                    guard w.offset + plain.count <= flash.count else { writeOp = nil; return fail(op, 0x08) }
                    flash.replaceSubrange(w.offset..<w.offset + plain.count, with: plain)
                }
            } else {
                let at = w.offset + Int(seq) * w.blockSize
                guard at + body.count <= flash.count else { return fail(op, 0x08) }
                flash.replaceSubrange(at..<at + body.count, with: body)
            }
            writeOp = w
            return [response(op)]

        case ESPOp.flashEnd, ESPOp.flashDeflEnd:
            writeOp = nil
            return [response(op)]

        case ESPOp.spiFlashMD5:
            guard let addr = try? r.u32(), let size = try? r.u32(), Int(addr) + Int(size) <= flash.count else { return fail(op, 0x06) }
            let md5 = Insecure.MD5.hash(data: flash[Int(addr)..<Int(addr) + Int(size)])
            if inStub { return [response(op, payload: Array(md5))] }
            return [response(op, payload: Array(md5.map { String(format: "%02x", $0) }.joined().utf8))]

        case ESPOp.eraseFlash:
            guard inStub else { return fail(op, 0x05) }
            flash = [UInt8](repeating: 0xFF, count: flash.count)
            return [response(op)]

        case ESPOp.readFlash:
            guard inStub, let offset = try? r.u32(), let length = try? r.u32(), let block = try? r.u32(), block > 0,
                  Int(offset) + Int(length) <= flash.count else { return fail(op, 0x05) }
            var out = [response(op)]
            var at = Int(offset)
            let end = at + Int(length)
            while at < end {
                let n = min(Int(block), end - at)
                out.append(Array(flash[at..<at + n]))
                at += n
            }
            out.append(Array(Insecure.MD5.hash(data: flash[Int(offset)..<end])))
            return out

        default:
            return fail(op, 0x05)
        }
    }

    // MARK: Registers

    private func readReg(_ addr: UInt32) -> UInt32 {
        if addr == ESPChip.magicRegisterAddress { return chip.magicValue ?? 0 }
        return regs[addr] ?? 0
    }

    private func writeReg(_ addr: UInt32, _ value: UInt32) {
        let s = chip.spi
        regs[addr] = value
        if addr == s.cmd, value & (1 << 18) != 0 {
            if (regs[s.base + s.usr2] ?? 0) & 0xFF == 0x9F { regs[s.base + s.w0] = flashID }
            regs[s.cmd] = value & ~(1 << 18)
        }
    }
}
