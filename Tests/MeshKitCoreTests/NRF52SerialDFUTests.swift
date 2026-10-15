import Foundation
import Testing
@testable import MeshKitCore

/// A software Adafruit bootloader in serial DFU mode: it decodes SLIP/HCI frames, checks the header checksum, sequence
/// numbers and CRC like the real one, acknowledges each packet and records what it was sent.
final class SimulatedSerialDFU: ByteTransport, @unchecked Sendable {
    private let broadcaster = DataBroadcaster()
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private(set) var commands: [UInt32] = []
    private(set) var startSizes: [UInt32] = []
    private(set) var initPacket: [UInt8] = []
    private(set) var firmware: [UInt8] = []
    private(set) var problems: [String] = []
    private var expectedSequence = 1
    var dropFirstAckOfPacket: Int?
    private var dropped = false

    func subscribe() -> AsyncStream<Data> { broadcaster.subscribe() }
    func close() { broadcaster.finish() }

    func send(_ data: Data) async throws {
        var complete: [[UInt8]] = []
        lock.withLock {
            for b in data {
                if b == 0xC0 { if !buffer.isEmpty { complete.append(buffer); buffer = [] } } else { buffer.append(b) }
            }
        }
        for frame in complete { handle(frame) }
    }

    private func handle(_ raw: [UInt8]) {
        var body: [UInt8] = []
        var escaped = false
        for b in raw {
            if escaped { body.append(b == 0xDC ? 0xC0 : 0xDB); escaped = false } else if b == 0xDB { escaped = true } else { body.append(b) }
        }
        lock.lock(); defer { lock.unlock() }
        guard body.count >= 6 else { problems.append("short frame"); return }
        let crc = UInt16(body[body.count - 2]) | UInt16(body[body.count - 1]) << 8
        let content = Array(body.dropLast(2))
        if NRF52HCI.crc16(content) != crc { problems.append("bad CRC"); return }
        if UInt8(truncatingIfNeeded: (~(Int(content[0]) + Int(content[1]) + Int(content[2]))) + 1) != content[3] { problems.append("bad header checksum"); return }
        let sequence = Int(content[0] & 0x07)
        let length = Int(content[1] >> 4) | Int(content[2]) << 4
        let payload = Array(content[4...])
        if payload.count != length { problems.append("length mismatch"); return }
        if sequence != expectedSequence {
            problems.append("sequence \(sequence), expected \(expectedSequence)")
        }
        let command = payload[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let rest = Array(payload.dropFirst(4))
        if sequence == expectedSequence {
            expectedSequence = (expectedSequence + 1) % 8
            commands.append(command)
            switch command {
            case NRF52HCI.startPacket:
                startSizes = stride(from: 4, to: 16, by: 4).map { i in rest[i..<i + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
                startSizes.insert(rest[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }, at: 0)
            case NRF52HCI.initPacket: initPacket = rest
            case NRF52HCI.dataPacket: firmware += rest
            default: break
            }
        }
        if let n = dropFirstAckOfPacket, commands.count == n, !dropped { dropped = true; expectedSequence = sequence; commands.removeLast(); if command == NRF52HCI.dataPacket { firmware.removeLast(rest.count) }; return }
        let ack = (sequence + 1) % 8
        var header: [UInt8] = [UInt8(ack << 3 | 0x80 | 0x40), 0, 0]
        header.append(UInt8(truncatingIfNeeded: (~(Int(header[0]) + Int(header[1]) + Int(header[2]))) + 1))
        let crcOut = NRF52HCI.crc16(header)
        broadcaster.yield(Data([0xC0] + NRF52HCI.slipEncode(header + [UInt8(crcOut & 0xFF), UInt8(crcOut >> 8)]) + [0xC0]))
    }
}

@Suite struct NRF52SerialDFUTests {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

    @Test func framingMatchesTheReferenceImplementation() {
        #expect(NRF52HCI.crc16(Array("123456789".utf8)) == 0x29B1)
        var start = NRF52HCI.le32(3) + NRF52HCI.le32(4) + NRF52HCI.le32(0) + NRF52HCI.le32(0) + NRF52HCI.le32(1000)
        #expect(hex(NRF52HCI.packet(sequence: 1, payload: start)) == "c0 d1 4e 01 e0 03 00 00 00 04 00 00 00 00 00 00 00 00 00 00 00 e8 03 00 00 12 f7 c0")
        start = NRF52HCI.le32(4) + [0xC0, 0xDB, 1, 2, 3]
        #expect(hex(NRF52HCI.packet(sequence: 7, payload: start)) == "c0 c7 9e 00 9b 04 00 00 00 db dc db dd 01 02 03 4f 73 c0")
        #expect(hex(NRF52HCI.packet(sequence: 0, payload: NRF52HCI.le32(5))) == "c0 c8 4e 00 ea 05 00 00 00 36 0a c0")
    }

    @Test func readsTheAcknowledgementNumber() {
        #expect(NRF52HCI.ackNumber(inFrame: [0xD0, 0, 0, 0x30, 0x12, 0x34]) == 2)
        #expect(NRF52HCI.ackNumber(inFrame: []) == nil)
    }

    @Test func readsADFUZip() async throws {
        let package = try await NRF52DFUPackage.read(zip: Self.zip(files: [
            ("manifest.json", #"{"manifest":{"application":{"bin_file":"firmware.bin","dat_file":"firmware.dat"},"dfu_version":0.5}}"#),
            ("firmware.dat", "INIT"), ("firmware.bin", "FIRMWARE")]))
        #expect(package.initPacket == Data("INIT".utf8) && package.firmware == Data("FIRMWARE".utf8))
        await #expect(throws: NRF52DFUPackage.PackageError.self) {
            _ = try await NRF52DFUPackage.read(zip: Self.zip(files: [("manifest.json", #"{"manifest":{"softdevice":{"bin_file":"s.bin","dat_file":"s.dat"}}}"#)]))
        }
    }

    @Test func sendsTheStartInitDataAndStopPacketsInOrder() async throws {
        let firmware = Data((0..<2_500).map { UInt8(truncatingIfNeeded: $0 &* 7) } + [0xC0, 0xDB, 0xC0])
        let initPacket = Data([0x52, 0x00, 0xFF, 0xFF, 0xDB, 0xC0, 0x01])
        let device = SimulatedSerialDFU()
        let flasher = NRF52SerialDFUFlasher(portPath: "/dev/cu.fake", package: NRF52DFUPackage(initPacket: initPacket, firmware: firmware),
                                            waitScale: 0, touchPort: {}, openPort: { device })
        let states = Locked<[String: FlashStep.State]>([:])
        try await flasher.run { id, state in states.value[id] = state }
        #expect(device.problems.isEmpty, "\(device.problems)")
        #expect(device.commands.first == NRF52HCI.startPacket && device.commands.dropFirst().first == NRF52HCI.initPacket)
        #expect(device.commands.last == NRF52HCI.stopDataPacket)
        #expect(device.commands.filter { $0 == NRF52HCI.dataPacket }.count == (firmware.count + 511) / 512)
        #expect(device.startSizes == [NRF52HCI.updateModeApplication, 0, 0, UInt32(firmware.count)])
        #expect(device.initPacket == [UInt8](initPacket) + [0, 0])
        #expect(device.firmware == [UInt8](firmware))
        for id in ["touch", "connect", "erase", "write", "activate"] { #expect(states.value[id] == FlashStep.State.done, "\(id)") }
    }

    @Test func aLostAcknowledgementIsRetried() async throws {
        let device = SimulatedSerialDFU()
        device.dropFirstAckOfPacket = 5
        let firmware = Data(repeating: 0x42, count: 3_000)
        let flasher = NRF52SerialDFUFlasher(portPath: "/dev/cu.fake", package: NRF52DFUPackage(initPacket: Data([1]), firmware: firmware),
                                            waitScale: 0, touchPort: {}, openPort: { device })
        try await flasher.run { _, _ in }
        #expect(device.firmware == [UInt8](firmware))
        #expect(device.commands.last == NRF52HCI.stopDataPacket)
    }

    static func zip(files: [(String, String)]) -> Data {
        // Stored (uncompressed) entries are enough for the reader.
        var out = Data(), central = Data()
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }) }
        for (name, content) in files {
            let body = Data(content.utf8), nameData = Data(name.utf8)
            var crc: UInt32 = 0xFFFF_FFFF
            for b in body { crc ^= UInt32(b); for _ in 0..<8 { crc = crc & 1 == 1 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 } }
            crc ^= 0xFFFF_FFFF
            let offset = UInt32(out.count)
            let size = UInt32(body.count)
            var local = Data()
            local.append(le32(0x0403_4B50)); local.append(le16(20)); local.append(le16(0)); local.append(le16(0))
            local.append(le16(0)); local.append(le16(0)); local.append(le32(crc)); local.append(le32(size)); local.append(le32(size))
            local.append(le16(nameData.count)); local.append(le16(0)); local.append(nameData); local.append(body)
            out.append(local)
            var entry = Data()
            entry.append(le32(0x0201_4B50)); entry.append(le16(20)); entry.append(le16(20)); entry.append(le16(0)); entry.append(le16(0))
            entry.append(le16(0)); entry.append(le16(0)); entry.append(le32(crc)); entry.append(le32(size)); entry.append(le32(size))
            entry.append(le16(nameData.count)); entry.append(le16(0)); entry.append(le16(0)); entry.append(le16(0)); entry.append(le16(0))
            entry.append(le32(0)); entry.append(le32(offset)); entry.append(nameData)
            central.append(entry)
        }
        let centralOffset = UInt32(out.count)
        var end = Data()
        end.append(le32(0x0605_4B50)); end.append(le16(0)); end.append(le16(0)); end.append(le16(files.count)); end.append(le16(files.count))
        end.append(le32(UInt32(central.count))); end.append(le32(centralOffset)); end.append(le16(0))
        out.append(central); out.append(end)
        return out
    }
}

/// A bootloader whose USB port disappears under the host partway through, as happens when a board re-enumerates.
final class DroppingSerialDFU: ByteTransport, @unchecked Sendable {
    private let inner = SimulatedSerialDFU()
    private let lock = NSLock()
    private var sends = 0
    let dropAfter: Int
    init(dropAfter: Int) { self.dropAfter = dropAfter }
    func subscribe() -> AsyncStream<Data> { inner.subscribe() }
    func close() { inner.close() }
    func send(_ data: Data) async throws {
        let n = lock.withLock { sends += 1; return sends }
        if n > dropAfter { throw SerialError.closed }
        try await inner.send(data)
    }
}

extension NRF52SerialDFUTests {
    @Test func aPortThatDisappearsMidSessionIsReopenedAndTheSessionRestarted() async throws {
        let first = DroppingSerialDFU(dropAfter: 4)
        let second = SimulatedSerialDFU()
        let queue = Locked<[ByteTransport]>([first, second])
        let firmware = Data(repeating: 0x42, count: 3_000)
        let flasher = NRF52SerialDFUFlasher(portPath: "/dev/cu.fake", package: NRF52DFUPackage(initPacket: Data([1]), firmware: firmware),
                                            waitScale: 0, touchPort: {}, openPort: { queue.value.removeFirst() })
        try await flasher.run { _, _ in }
        #expect(second.problems.isEmpty)
        #expect(second.firmware == [UInt8](firmware))
        #expect(second.commands.last == NRF52HCI.stopDataPacket)
    }

    @Test func aBoardThatKeepsDroppingIsEventuallyReported() async throws {
        let flasher = NRF52SerialDFUFlasher(portPath: "/dev/cu.fake", package: NRF52DFUPackage(initPacket: Data([1]), firmware: Data(repeating: 1, count: 600)),
                                            waitScale: 0, touchPort: {}, openPort: { DroppingSerialDFU(dropAfter: 1) })
        await #expect(throws: SerialError.self) { try await flasher.run { _, _ in } }
    }
}
