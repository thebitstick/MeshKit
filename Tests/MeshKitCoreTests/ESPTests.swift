import Foundation
import Testing
@testable import MeshKitCore

@Suite struct SLIPTests {
    @Test func escapesDelimiterAndEscapeBytes() {
        let wire = [UInt8](SLIP.encode([0x01, 0xC0, 0x02, 0xDB, 0x03]))
        #expect(wire == [0xC0, 0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03, 0xC0])
    }

    @Test func roundTripsEveryByteValue() {
        let all = (0...255).map(UInt8.init)
        var d = SLIPDecoder()
        #expect(d.feed(SLIP.encode(all)) == [all])
    }

    @Test func splitsAcrossChunksAndIgnoresBootNoise() {
        var d = SLIPDecoder()
        let noise = Data("ets Jun  8 2016 00:22:57\r\nrst:0x1\r\n".utf8)
        let wire = SLIP.encode([1, 2, 3, 4]) + SLIP.encode([9])
        #expect(d.feed(noise).isEmpty)
        #expect(d.discardedBytes == noise.count)
        #expect(d.feed(wire.prefix(3)).isEmpty)
        #expect(d.feed(wire.dropFirst(3)) == [[1, 2, 3, 4], [9]])
    }

    @Test func badEscapeDropsOnlyThatFrame() {
        var d = SLIPDecoder()
        let bad = Data([0xC0, 0x01, 0xDB, 0x00, 0x02, 0xC0])
        #expect(d.feed(bad + SLIP.encode([7, 7])) == [[7, 7]])
    }

    @Test func backToBackDelimitersAreNotEmptyFrames() {
        var d = SLIPDecoder()
        #expect(d.feed(Data([0xC0, 0xC0, 0x05, 0xC0])) == [[5]])
    }
}

@Suite struct ZLibTests {
    @Test func adlerKnownVector() {
        #expect(ZLib.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(ZLib.adler32([]) == 1)
    }

    @Test func compressRoundTripAndShrinksRedundantData() throws {
        let data = [UInt8](repeating: 0xFF, count: 100_000) + (0..<5000).map { UInt8($0 & 0xFF) }
        let z = try #require(ZLib.compress(data))
        #expect(z.count < data.count / 10)
        #expect(z[0] == 0x78)
        #expect(ZLib.decompress(z, expectedSize: data.count) == data)
    }

    @Test func detectsCorruptTrailer() throws {
        var z = try #require(ZLib.compress([UInt8](repeating: 1, count: 1000)))
        z[z.count - 1] ^= 0xFF
        #expect(ZLib.inflate(z, capacity: 4096) == nil)
    }
}

@Suite struct ESPResetTests {
    private func loader(_ sim: SimulatedESPDevice) async -> ESPLoader {
        let l = ESPLoader(port: sim)
        await l.start()
        return l
    }

    @Test func tightResetEntersBootloaderOnUARTBridge() async throws {
        let sim = SimulatedESPDevice(chip: .esp32s3)
        let l = await loader(sim)
        try await l.connect(strategies: [.tight(delay: 0.05)], attempts: 1)
        #expect(sim.isInBootloader)
        await l.stop()
    }

    @Test func classicResetEntersBootloaderOnUARTBridge() async throws {
        let sim = SimulatedESPDevice(chip: .esp32)
        let l = await loader(sim)
        try await l.connect(strategies: [.classic(delay: 0.05)], attempts: 1)
        #expect(sim.isInBootloader)
        await l.stop()
    }

    @Test func usbJTAGSequenceWorksOnNativeUSB() async throws {
        let sim = SimulatedESPDevice(chip: .esp32c3, usbJTAG: true)
        let l = await loader(sim)
        try await l.connect(strategies: [.usbJTAGSerial], attempts: 1)
        #expect(sim.isInBootloader)
        await l.stop()
    }

    @Test func fallsThroughToTheStrategyThatWorks() async throws {
        let sim = SimulatedESPDevice(chip: .esp32c3, usbJTAG: true)
        let l = await loader(sim)
        // UART-style sequences do nothing useful on the USB-Serial-JTAG block; the last entry does.
        try await l.connect(strategies: [.classic(delay: 0.05), .usbJTAGSerial], attempts: 2)
        #expect(sim.isInBootloader)
        await l.stop()
    }

    @Test func wrongStrategyReportsBootHint() async throws {
        let sim = SimulatedESPDevice(chip: .esp32s3)
        let l = await loader(sim)
        let error = await #expect(throws: ESPError.self) {
            try await l.connect(strategies: [.usbJTAGSerial], attempts: 1)
        }
        if case .noSync(let hint)? = error { #expect(hint.contains("started normally")) } else { Issue.record("expected noSync, got \(String(describing: error))") }
        await l.stop()
    }

    @Test func strategyOrderPrefersUSBForUsbmodemPorts() {
        if case .usbJTAGSerial = ESPResetStrategy.sequence(forPortPath: "/dev/cu.usbmodem1101")[0] {} else { Issue.record("usbmodem should try USB-JTAG first") }
        if case .tight = ESPResetStrategy.sequence(forPortPath: "/dev/cu.usbserial-0001")[0] {} else { Issue.record("usbserial should try tight reset first") }
    }
}

@Suite struct ESPLoaderTests {
    private func attached(_ chip: ESPChip = .esp32s3, flashSize: Int = 8 << 20) async throws -> (ESPLoader, SimulatedESPDevice) {
        let sim = SimulatedESPDevice(chip: chip, flashSize: flashSize, startInBootloader: true)
        let l = ESPLoader(port: sim)
        await l.start()
        try await l.sync()
        return (l, sim)
    }

    private static func pattern(_ n: Int, seed: UInt8 = 1) -> [UInt8] {
        var x = UInt32(seed) &* 2_654_435_761
        return (0..<n).map { i in
            x = x &* 1_664_525 &+ 1_013_904_223
            return (i / 4096) % 3 == 0 ? UInt8(truncatingIfNeeded: x >> 24) : 0xFF
        }
    }

    @Test(arguments: [ESPChip.esp32, .esp32s2, .esp32s3, .esp32c3, .esp32c6, .esp32h2, .esp32c2])
    func detectsEveryChip(chip: ESPChip) async throws {
        let (l, _) = try await attached(chip)
        #expect(try await l.detectChip() == chip)
        await l.stop()
    }

    @Test func detectsFlashSize() async throws {
        for size in [4 << 20, 8 << 20, 16 << 20] {
            let (l, _) = try await attached(.esp32s3, flashSize: size)
            _ = try await l.detectChip()
            let id = try await l.detectFlash()
            #expect(id.sizeBytes == size)
            #expect(id.manufacturer == 0xEF)
            await l.stop()
        }
    }

    @Test func romCompressedWriteVerifies() async throws {
        let (l, sim) = try await attached(.esp32s3)
        _ = try await l.detectChip()
        try await l.attachFlash()
        let image = Self.pattern(300_000)
        try await l.writeFlash(image, at: 0)
        #expect(Array(sim.flashContents[0..<image.count]) == image)
        await l.stop()
    }

    @Test func romUncompressedWriteVerifies() async throws {
        let (l, sim) = try await attached(.esp32c3)
        _ = try await l.detectChip()
        let image = Self.pattern(70_001)
        try await l.writeFlash(image, at: 0x10000, compress: false)
        let flash = sim.flashContents
        #expect(Array(flash[0x10000..<0x10000 + image.count]) == image)
        #expect(flash[0x10000 + image.count] == 0xFF)
        await l.stop()
    }

    @Test func romAlignsUnalignedAddressesToASector() async throws {
        let (l, sim) = try await attached(.esp32s3)
        _ = try await l.detectChip()
        sim.preload([UInt8](repeating: 0x11, count: 0x1000), at: 0x20000)
        let image = Self.pattern(5000, seed: 9)
        try await l.writeFlash(image, at: 0x20010)
        let flash = sim.flashContents
        #expect(Array(flash[0x20010..<0x20010 + image.count]) == image)
        // The ROM can't write mid-sector, so the 16 bytes before the image are rewritten as erased flash.
        #expect(flash[0x20000..<0x20010].allSatisfy { $0 == 0xFF })
        await l.stop()
    }

    @Test func retriesABlockAfterChecksumError() async throws {
        let (l, sim) = try await attached(.esp32s3)
        _ = try await l.detectChip()
        sim.corruptChecksumOnce = true
        let image = Self.pattern(20_000, seed: 4)
        try await l.writeFlash(image, at: 0, compress: false)
        #expect(Array(sim.flashContents[0..<image.count]) == image)
        await l.stop()
    }

    @Test func stubWriteReadAndEraseRoundTrip() async throws {
        let (l, sim) = try await attached(.esp32s3)
        _ = try await l.detectChip()
        try await l.runStub()
        #expect(await l.isStub)
        #expect(sim.isStubRunning)

        let image = Self.pattern(200_000, seed: 7)
        try await l.writeFlash(image, at: 0x8000)
        let back = try await l.readFlash(offset: 0x8000, length: image.count + 0 + (4096 - image.count % 4096) % 4096)
        #expect(Array(back[0..<image.count]) == image)

        try await l.eraseFlash()
        #expect(sim.flashContents.allSatisfy { $0 == 0xFF })
        await l.stop()
    }

    @Test func readWithoutStubIsRefused() async throws {
        let (l, _) = try await attached(.esp32s3)
        _ = try await l.detectChip()
        await #expect(throws: ESPError.notInStubMode("Reading flash")) { _ = try await l.readFlash(offset: 0, length: 4096) }
        await l.stop()
    }

    @Test func changesBaudRate() async throws {
        let (l, sim) = try await attached(.esp32s3)
        _ = try await l.detectChip()
        try await l.runStub()
        try await l.changeBaudRate(921_600)
        #expect(sim.currentBaud == 921_600)
        let image = Self.pattern(10_000)
        try await l.writeFlash(image, at: 0)
        await l.stop()
    }

    @Test func flashMD5MatchesLocalDigest() async throws {
        let (l, sim) = try await attached(.esp32s3)
        _ = try await l.detectChip()
        let bytes = Self.pattern(8192, seed: 3)
        sim.preload(bytes, at: 0x1000)
        let md5 = try await l.flashMD5(address: 0x1000, size: bytes.count)
        #expect(md5.count == 32)
        try await l.runStub()
        #expect(try await l.flashMD5(address: 0x1000, size: bytes.count) == md5)
        await l.stop()
    }

    @Test func reportsDeviceErrorsWithMeaning() async throws {
        let (l, _) = try await attached(.esp32s3, flashSize: 1 << 20)
        _ = try await l.detectChip()
        let error = await #expect(throws: ESPError.self) { try await l.writeFlash(Self.pattern(4096), at: 2 << 20) }
        #expect(error?.localizedDescription.contains("Failed to") == true)
        await l.stop()
    }
}

/// Writes the commands a scenario sends to a file, in the same format `esp-sim --cmdlog` uses, so
/// the request stream can be diffed against the one esptool sends for the same operation.
@Suite struct ESPCommandLogExport {
    @Test func exportsRequestStreamsWhenAsked() async throws {
        guard let dir = ProcessInfo.processInfo.environment["ESP_CMDLOG_DIR"] else { return }
        func dump(_ sim: SimulatedESPDevice, to name: String) throws {
            let lines = sim.commands.map { c in
                String(format: "%02x %d ", c.op, c.data.count) + c.data.prefix(64).map { String(format: "%02x", $0) }.joined()
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: "\(dir)/\(name)", atomically: true, encoding: .utf8)
        }
        let image = (0..<270_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) }

        var sim = SimulatedESPDevice(chip: .esp32s3, flashSize: 8 << 20, startInBootloader: true)
        var l = ESPLoader(port: sim); await l.start()
        try await l.sync(); _ = try await l.detectChip(); try await l.attachFlash()
        let id = try await l.detectFlash(); try await l.setFlashParameters(size: id.sizeBytes ?? 4 << 20)
        try await l.writeFlash(image, at: 0x10000)
        try dump(sim, to: "swift-rom-z.log"); await l.stop()

        sim = SimulatedESPDevice(chip: .esp32s3, flashSize: 8 << 20, startInBootloader: true)
        l = ESPLoader(port: sim); await l.start()
        try await l.sync(); _ = try await l.detectChip(); try await l.runStub()
        let id2 = try await l.detectFlash(); try await l.setFlashParameters(size: id2.sizeBytes ?? 4 << 20)
        try await l.writeFlash(image, at: 0x10000)
        _ = try await l.readFlash(offset: 0x10000, length: 8192)
        try dump(sim, to: "swift-stub-z.log"); await l.stop()
    }
}

@Suite struct ESPFlasherTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(String, FlashStep.State)] = []
        func add(_ id: String, _ s: FlashStep.State) { lock.withLock { events.append((id, s)) } }
        var all: [(String, FlashStep.State)] { lock.withLock { events } }
        func finalState(of id: String) -> FlashStep.State? { all.last { $0.0 == id }?.1 }
    }

    private static func firmware(chip: ESPChip, size: Int, seed: UInt8 = 1) -> [UInt8] {
        var bytes = (0..<size).map { i in UInt8(truncatingIfNeeded: (i &* 31) &+ (i >> 8) &* Int(seed)) }
        let off = Int(chip.bootloaderOffset)
        bytes.replaceSubrange(0..<off, with: repeatElement(0xFF, count: off))
        bytes[off] = 0xE9
        bytes[off + 12] = UInt8(chip.imageChipID & 0xFF); bytes[off + 13] = UInt8(chip.imageChipID >> 8)
        return bytes
    }

    private func flasher(_ sim: SimulatedESPDevice, _ job: ESPFlashJob, path: String = "/dev/cu.usbserial-0001", backup: Bool = true,
                         sink: (@Sendable (ESPFlashBackup) throws -> Void)? = nil) -> ESPFlasher {
        ESPFlasher(portPath: path, job: job, options: ESPFlashOptions(baudRate: 921_600, useStub: true, backupFirst: backup),
                   openPort: { sim }, onBackup: sink)
    }

    @Test func fullFlowThroughAutoResetCircuit() async throws {
        let sim = SimulatedESPDevice(chip: .esp32s3, flashSize: 4 << 20)
        let old = [UInt8](repeating: 0x42, count: 300_000)
        sim.preload(old, at: 0)
        let rec = Recorder()
        let saved = Locked<ESPFlashBackup?>(nil)
        let image = Self.firmware(chip: .esp32s3, size: 200_000)

        let f = flasher(sim, .single(Data(image)), sink: { saved.value = $0 })
        #expect(f.steps.map(\.id) == ["connect", "backup", "write", "verify", "reset"])
        try await f.run { rec.add($0, $1) }

        #expect(Array(sim.flashContents[0..<image.count]) == image)
        let backup = try #require(saved.value)
        #expect(backup.chip == .esp32s3)
        #expect(backup.data.count == 4 << 20)
        #expect(Array(backup.data[0..<old.count]) == old)
        #expect(!sim.isInBootloader)
        for id in ["connect", "backup", "write", "verify", "reset"] { #expect(rec.finalState(of: id) == .done, "step \(id)") }
        #expect(sim.currentBaud == 921_600)
    }

    @Test func nativeUSBBoardsUseTheUSBJTAGReset() async throws {
        let sim = SimulatedESPDevice(chip: .esp32c3, flashSize: 4 << 20, usbJTAG: true)
        let image = Self.firmware(chip: .esp32c3, size: 50_000)
        let f = flasher(sim, .single(Data(image)), path: "/dev/cu.usbmodem1101", backup: false)
        try await f.run { _, _ in }
        #expect(Array(sim.flashContents[0..<image.count]) == image)
    }

    @Test func refusesAnImageBuiltForAnotherChipBeforeErasingAnything() async throws {
        let sim = SimulatedESPDevice(chip: .esp32s3, flashSize: 4 << 20)
        let before = [UInt8](repeating: 0x42, count: 100_000)
        sim.preload(before, at: 0)
        let rec = Recorder()
        let wrongChip = Self.firmware(chip: .esp32c3, size: 50_000)
        let error = await #expect(throws: ESPError.self) {
            try await flasher(sim, .single(Data(wrongChip)), backup: false).run { rec.add($0, $1) }
        }
        #expect(error == .imageForDifferentChip(found: "ESP32-C3", expected: "ESP32-S3"))
        #expect(Array(sim.flashContents[0..<before.count]) == before)
        if case .failed? = rec.finalState(of: "connect") {} else { Issue.record("connect step should report the failure") }
    }

    @Test func refusesAnImageLargerThanTheFlash() async throws {
        let sim = SimulatedESPDevice(chip: .esp32s3, flashSize: 1 << 20)
        let error = await #expect(throws: ESPError.self) {
            try await flasher(sim, .single(Data(Self.firmware(chip: .esp32s3, size: 2 << 20))), backup: false).run { _, _ in }
        }
        if case .imageTooLarge? = error {} else { Issue.record("expected imageTooLarge, got \(String(describing: error))") }
    }

    @Test func classicESP32ChecksTheHeaderAtItsBootloaderOffset() throws {
        let good = Self.firmware(chip: .esp32, size: 20_000)
        try ESPImageCheck.validate(good, at: 0, chip: .esp32, flashSize: 4 << 20)
        let wrong = Self.firmware(chip: .esp32s3, size: 20_000)
        #expect(throws: ESPError.imageForDifferentChip(found: "ESP32-S3", expected: "ESP32")) {
            try ESPImageCheck.validate(wrong, at: 0, chip: .esp32, flashSize: 4 << 20)
        }
        var filesystem = [UInt8](repeating: 0, count: 4096); filesystem[0] = 0xE9; filesystem[12] = 9
        try ESPImageCheck.validate(filesystem, at: 0x670000, chip: .esp32, flashSize: 8 << 20, isApplication: false)
        var s3AtClassicOffset = good
        s3AtClassicOffset[0x1000 + 12] = 9
        #expect(throws: ESPError.imageForDifferentChip(found: "ESP32-S3", expected: "ESP32")) {
            try ESPImageCheck.validate(s3AtClassicOffset, at: 0, chip: .esp32, flashSize: nil)
        }
    }

    @Test func backupStoreRoundTripsAndSortsNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let older = ESPFlashBackup(chip: .esp32s3, flashSize: 8 << 20, date: Date(timeIntervalSince1970: 1_700_000_000), data: [1, 2, 3])
        let newer = ESPFlashBackup(chip: .esp32, flashSize: 4 << 20, date: Date(timeIntervalSince1970: 1_800_000_000), data: [4, 5])
        try FlashBackupStore.save(older, in: dir)
        let url = try FlashBackupStore.save(newer, in: dir)
        let list = FlashBackupStore.list(in: dir)
        #expect(list.map(\.chip) == ["ESP32", "ESP32-S3"])
        #expect(list[0].url.lastPathComponent == url.lastPathComponent)   // /var vs /private/var aside
        #expect(list[0].size == 2)
        #expect(try Data(contentsOf: list[0].url) == Data([4, 5]))
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

@Suite struct SerialPortTests {
    private struct PTY {
        let master: Int32
        let slavePath: String
        func close() { Darwin.close(master) }
    }

    private func makePTY() throws -> PTY {
        var master: Int32 = 0, slave: Int32 = 0
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw SerialError.openFailed("pty", errno) }
        Darwin.close(slave)
        return PTY(master: master, slavePath: String(cString: name))
    }

    @Test func readsAndWritesBytes() async throws {
        let pty = try makePTY(); defer { pty.close() }
        let port = try SerialPort(path: pty.slavePath)
        defer { port.close() }
        var incoming = port.subscribe().makeAsyncIterator()

        let hello = [UInt8]("hello".utf8)
        _ = hello.withUnsafeBytes { write(pty.master, $0.baseAddress, $0.count) }
        var got = Data()
        while got.count < hello.count, let chunk = await incoming.next() { got += chunk }
        #expect([UInt8](got) == hello)

        let payload: [UInt8] = [0x00, 0x03, 0x0A, 0x0D, 0x11, 0x13, 0x1A, 0x7F, 0xC0, 0xDB, 0xFF]
        try await port.send(Data(payload))
        var echoed = [UInt8](repeating: 0, count: payload.count)
        var total = 0
        let deadline = Date().addingTimeInterval(2)
        _ = fcntl(pty.master, F_SETFL, O_NONBLOCK)
        while total < payload.count, Date() < deadline {
            let n = echoed.withUnsafeMutableBytes { read(pty.master, $0.baseAddress! + total, payload.count - total) }
            if n > 0 { total += n } else { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(echoed == payload)
    }

    @Test func modemLineAndBaudCallsUseValidIoctls() throws {
        let pty = try makePTY(); defer { pty.close() }
        let port = try SerialPort(path: pty.slavePath)
        defer { port.close() }
        try port.setBaudRate(460_800)
        // A pty has no modem lines, so TIOCMGET/TIOCMSET may fail with ENOTTY, but they must never fail with
        // EINVAL-style errors that would mean a wrong request number, and must not disturb the port.
        do { try port.setLines(dtr: true, rts: false) } catch SerialError.writeFailed(let e) { #expect(e == ENOTTY || e == EOPNOTSUPP || e == EINVAL || e == ENODEV) }
        try port.setBaudRate(115_200)
    }

    @Test func closedPortsRefuseEveryOperationInsteadOfTouchingAReusedDescriptor() async throws {
        let pty = try makePTY(); defer { pty.close() }
        let port = try SerialPort(path: pty.slavePath)
        port.close()
        port.close()
        #expect(throws: SerialError.self) { try port.setLines(dtr: true, rts: false) }
        #expect(throws: SerialError.self) { try port.setBaudRate(460_800) }
        await #expect(throws: SerialError.self) { try await port.send(Data([1])) }
    }

    @Test func reportsMissingDevice() {
        #expect(throws: SerialError.self) { _ = try SerialPort(path: "/dev/cu.does-not-exist") }
    }
}
