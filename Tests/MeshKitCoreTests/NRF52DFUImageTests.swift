import Foundation
import Testing
@testable import MeshKitCore

@Suite struct NRF52DFUImageTests {
    private func uf2(_ pages: [UInt32: [UInt8]]) -> Data {
        var out = Data()
        let addresses = pages.keys.sorted()
        for (i, address) in addresses.enumerated() {
            var b: [UInt8] = []
            b.appendLE(UF2.magicStart0); b.appendLE(UF2.magicStart1); b.appendLE(UF2.familyFlag)
            b.appendLE(address); b.appendLE(UInt32(pages[address]!.count))
            b.appendLE(UInt32(i)); b.appendLE(UInt32(addresses.count)); b.appendLE(UInt32(0x2886_1667))
            var payload = pages[address]!
            payload += [UInt8](repeating: 0xFF, count: 476 - payload.count)
            b += payload
            b.appendLE(UF2.magicEnd)
            out.append(contentsOf: b)
        }
        return out
    }

    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// A flash image the way a bootloader's CURRENT.UF2 holds it: SoftDevice with its information block, then the application.
    private func backup(softDeviceEnd: UInt32 = 0x27000, firmwareID: UInt16 = 0x123, application: [UInt8]) -> Data {
        var pages: [UInt32: [UInt8]] = [:]
        for address in stride(from: UInt32(0x1000), to: softDeviceEnd, by: 256) { pages[address] = [UInt8](repeating: 0x11, count: 256) }
        var info = [UInt8](repeating: 0x11, count: 256)
        let magic = le32(NRF52SoftDevice.infoMagic) + le32(softDeviceEnd) + le32(UInt32(firmwareID))
        info.replaceSubrange(4..<16, with: magic)
        pages[0x3000] = info
        for (i, chunk) in stride(from: 0, to: application.count, by: 256).enumerated() {
            pages[softDeviceEnd + UInt32(i * 256)] = Array(application[chunk..<min(chunk + 256, application.count)])
        }
        return uf2(pages)
    }

    @Test func buildsTheInitPacketNrfutilWould() {
        let firmware = Data(repeating: 0x42, count: 700)
        let package = NRF52DFUPackage(application: firmware, softDevice: 0x123)
        let crc = NRF52HCI.crc16([UInt8](firmware))
        #expect([UInt8](package.initPacket) == [0x52, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1, 0, 0x23, 0x01, UInt8(crc & 0xFF), UInt8(crc >> 8)])
        #expect(package.softDevices == [0x123])
    }

    @Test func matchesAPackageMadeByTheReferenceTool() {
        // Meshtastic's Wio Tracker L1 package: SoftDevice 0x123, firmware CRC 28672 (0x7000).
        let dat = Data([0x52, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1, 0, 0x23, 0x01, 0x00, 0x70])
        let package = NRF52DFUPackage(initPacket: dat, firmware: Data())
        #expect(package.softDevices == [0x123])
    }

    @Test func restoringKeepsOnlyTheApplicationAndNamesItsSoftDevice() throws {
        let app = (0..<600).map { UInt8(truncatingIfNeeded: $0 &* 3) }
        let package = try NRF52DFUPackage.restoring(backup: backup(application: app))
        #expect([UInt8](package.firmware) == app)
        #expect(package.softDevices == [0x123])
        #expect(package.initPacket.suffix(2) == Data([UInt8(NRF52HCI.crc16(app) & 0xFF), UInt8(NRF52HCI.crc16(app) >> 8)]))
    }

    @Test func aSixPointOneBoardStartsItsApplicationEarlier() throws {
        let app = [UInt8](repeating: 0x5A, count: 300)
        let package = try NRF52DFUPackage.restoring(backup: backup(softDeviceEnd: 0x26000, firmwareID: 0xB6, application: app))
        #expect([UInt8](package.firmware) == app && package.softDevices == [0xB6])
    }

    @Test func refusesAnImageWithoutASoftDevice() {
        let noSD = uf2([0x27000: [UInt8](repeating: 1, count: 256)])
        #expect(throws: NRF52DFUPackage.ImageError.self) { try NRF52DFUPackage.restoring(backup: noSD) }
        #expect(throws: NRF52DFUPackage.ImageError.self) { try NRF52DFUPackage.restoring(backup: Data("nope".utf8)) }
    }

    @Test func gapsInTheApplicationAreFilledWithErasedFlash() throws {
        let image = uf2([0x27000: [UInt8](repeating: 1, count: 256), 0x27200: [UInt8](repeating: 2, count: 100)])
        let package = try NRF52DFUPackage.application(fromUF2: image, startingAt: 0x27000, softDevice: 0x123)
        #expect(package.firmware.count == 0x200 + 100)
        #expect(package.firmware[0x100] == 0xFF && package.firmware[0x1FF] == 0xFF && package.firmware[0x200] == 2)
    }

    @Test func pickEraseToolByTheSoftDeviceThePackageNeeds() throws {
        let images = NRF52EraseImages(images: [
            "7.3": uf2([0x27000: [UInt8](repeating: 0x73, count: 256)]),
            "6.1": uf2([0x26000: [UInt8](repeating: 0x61, count: 256)]),
        ])
        let new = try NRF52DFUPackage.eraseTool(for: NRF52DFUPackage(application: Data([1]), softDevice: 0x123), from: images)
        #expect(new.firmware.first == 0x73 && new.softDevices == [0x123])
        let old = try NRF52DFUPackage.eraseTool(for: NRF52DFUPackage(application: Data([1]), softDevice: 0xB6), from: images)
        #expect(old.firmware.first == 0x61 && old.softDevices == [0xB6])
        #expect(throws: NRF52DFUPackage.ImageError.self) { try NRF52DFUPackage.eraseTool(for: NRF52DFUPackage(application: Data([1]), softDevice: 0xFFFE), from: images) }
        let wrongStart = NRF52EraseImages(images: ["7.3": uf2([0x26000: [UInt8](repeating: 1, count: 256)])])
        #expect(throws: NRF52DFUPackage.ImageError.self) { try NRF52DFUPackage.eraseTool(for: NRF52DFUPackage(application: Data([1]), softDevice: 0x123), from: wrongStart) }
    }

    @Test func aCleanInstallSendsTheEraseToolThenTheFirmware() async throws {
        let eraser = NRF52DFUPackage(application: Data(repeating: 0xEE, count: 1_200), softDevice: 0x123)
        let firmware = NRF52DFUPackage(application: Data(repeating: 0xAB, count: 2_000), softDevice: 0x123)
        let first = SimulatedSerialDFU(), second = SimulatedSerialDFU()
        let wiped = Locked(false)
        let touched = Locked(0)
        let flasher = NRF52SerialCleanFlasher(
            portPath: "/dev/cu.fake", eraser: eraser, package: firmware, waitScale: 0,
            touchPort: { touched.value += 1 },
            openPorts: [{ first }, { second }],
            wipeBoard: { #expect(first.commands.last == NRF52HCI.stopDataPacket && second.commands.isEmpty); wiped.value = true })
        let states = Locked<[String: FlashStep.State]>([:])
        try await flasher.run { id, state in states.value[id] = state }
        #expect(first.problems.isEmpty && second.problems.isEmpty)
        #expect(first.firmware == [UInt8](eraser.firmware) && second.firmware == [UInt8](firmware.firmware))
        #expect(second.commands.last == NRF52HCI.stopDataPacket)
        #expect(wiped.value && touched.value == 1)
        for step in flasher.steps { #expect(states.value[step.id] == FlashStep.State.done, "\(step.id)") }
    }

    @Test func aFailedWipeStopsBeforeTheFirmwareIsSent() async throws {
        let first = SimulatedSerialDFU(), second = SimulatedSerialDFU()
        let flasher = NRF52SerialCleanFlasher(
            portPath: "/dev/cu.fake", eraser: NRF52DFUPackage(application: Data(repeating: 1, count: 600), softDevice: 0x123),
            package: NRF52DFUPackage(application: Data(repeating: 2, count: 600), softDevice: 0x123), waitScale: 0, touchPort: {},
            openPorts: [{ first }, { second }], wipeBoard: { throw NRF52SerialDFUFlasher.DFUError.wipeTimedOut })
        await #expect(throws: NRF52SerialDFUFlasher.DFUError.self) { try await flasher.run { _, _ in } }
        #expect(second.commands.isEmpty)
    }
}

@Suite struct WipeDetectionTests {
    private func drive() -> UF2Volume { UF2Volume(url: URL(fileURLWithPath: "/Volumes/HT-n5262G"), model: "Heltec T096", boardID: "HT-n5262G", bootloader: "") }

    @Test func aDriveThatWasAlreadyMountedCountsOnlyOnceItHasGoneAndComeBack() async throws {
        let calls = Locked(0)
        // present when the tool is loaded, gone while it runs, back when the board has restarted
        let volumes: @Sendable () -> [UF2Volume] = { calls.value += 1; return (3...5).contains(calls.value) ? [] : [drive()] }
        let started = ContinuousClock.now
        try await NRF52SerialCleanFlasher.wipeThroughSerial(timeout: .seconds(30), logger: nil, volumes: volumes, ports: { [] })
        #expect(calls.value >= 6, "returned before the drive had left and come back")
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test func aBoardThatNeverComesBackTimesOut() async {
        await #expect(throws: NRF52SerialDFUFlasher.DFUError.self) {
            try await NRF52SerialCleanFlasher.wipeThroughSerial(timeout: .seconds(2), logger: nil, volumes: { [] }, ports: { [] })
        }
    }
}

@Suite struct AlreadyInBootloaderTests {
    @Test func aBoardShowingItsDriveIsNotTouchedAgain() async throws {
        let drive = UF2Volume(url: URL(fileURLWithPath: "/Volumes/HT-n5262G"), model: "Heltec T096", boardID: "HT-n5262G", bootloader: "")
        let device = SimulatedSerialDFU()
        // With no touch override, a touch would try to open this port and fail.
        let flasher = NRF52SerialDFUFlasher(portPath: "/dev/cu.does-not-exist", package: NRF52DFUPackage(initPacket: Data([1]), firmware: Data(repeating: 7, count: 700)),
                                            waitScale: 0, openPort: { device }, bootloaderDrives: { [drive] })
        try await flasher.run { _, _ in }
        #expect(device.firmware == [UInt8](Data(repeating: 7, count: 700)))
    }
}

@Suite struct WipeWithAnotherBoardTests {
    private func drive(_ name: String) -> UF2Volume { UF2Volume(url: URL(fileURLWithPath: "/Volumes/\(name)"), model: name, boardID: name, bootloader: "") }

    @Test func anotherBoardsDriveThatStaysMountedDoesNotEndTheWipe() async {
        let other = drive("OTHER")
        await #expect(throws: NRF52SerialDFUFlasher.DFUError.self) {
            try await NRF52SerialCleanFlasher.wipeThroughSerial(timeout: .seconds(2), logger: nil, volumes: { [other] }, ports: { [] })
        }
    }

    @Test func aDifferentDriveAppearingEndsTheWipe() async throws {
        let calls = Locked(0)
        let volumes: @Sendable () -> [UF2Volume] = { calls.value += 1; return calls.value < 3 ? [] : [drive("TARGET")] }
        try await NRF52SerialCleanFlasher.wipeThroughSerial(timeout: .seconds(30), logger: nil, volumes: volumes, ports: { [] })
        #expect(calls.value >= 3)
    }
}

@Suite struct BackupLabelsInTheBackgroundTests {
    @Test func listingWithoutReadingLabelsIsInstantAndLabelsAppearOnceRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("labels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes: [UInt8] = []
        bytes.appendLE(UF2.magicStart0); bytes.appendLE(UF2.magicStart1); bytes.appendLE(UF2.familyFlag)
        bytes.appendLE(UInt32(0x27000)); bytes.appendLE(UInt32(256)); bytes.appendLE(UInt32(0)); bytes.appendLE(UInt32(1)); bytes.appendLE(UInt32(0x2886_1667))
        var payload = [UInt8](" 2.7.26.54e0d8d ".utf8)
        payload += [UInt8](repeating: 0, count: 476 - payload.count)
        bytes += payload; bytes.appendLE(UF2.magicEnd)
        try NRF52BackupStore.save(Data(bytes), board: "Test Board", in: dir)
        #expect(NRF52BackupStore.list(in: dir, readLabels: false).first?.firmware == nil)
        #expect(NRF52BackupStore.list(in: dir, readLabels: true).first?.firmware == "Meshtastic 2.7.26 (54e0d8d)")
        #expect(NRF52BackupStore.list(in: dir, readLabels: false).first?.firmware == "Meshtastic 2.7.26 (54e0d8d)")
    }
}
