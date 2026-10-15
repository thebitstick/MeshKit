import Foundation
import Testing
@testable import MeshKitCore

@Suite struct NRF52BackupTests {
    private func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nrfbackup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// What a bootloader's CURRENT.UF2 looks like: SoftDevice and application, family 0x28861667 (not nRF52840).
    private func currentImage(blocks: Int = 6) -> Data { UF2Tests.makeUF2(blocks: blocks, family: 0x2886_1667) }

    @Test func savesAndListsBackupsNewestFirst() throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let older = Date(timeIntervalSince1970: 1_790_000_000), newer = older.addingTimeInterval(3_600)
        try NRF52BackupStore.save(currentImage(), board: "Seeed TRACKER L1", date: older, in: dir)
        try NRF52BackupStore.save(currentImage(blocks: 3), board: "Heltec T114", date: newer, in: dir)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let list = NRF52BackupStore.list(in: dir)
        #expect(list.map(\.board) == ["Heltec T114", "Seeed TRACKER L1"])
        #expect(list[0].size == 3 * 512 && list[1].size == 6 * 512)
        #expect(abs(list[1].date.timeIntervalSince(older)) < 1)
    }

    private func image(_ pages: [(address: UInt32, text: String)]) -> Data {
        var out = Data()
        for (i, page) in pages.enumerated() {
            var b: [UInt8] = []
            b.appendLE(UF2.magicStart0); b.appendLE(UF2.magicStart1); b.appendLE(UF2.familyFlag)
            b.appendLE(page.address); b.appendLE(UInt32(256))
            b.appendLE(UInt32(i)); b.appendLE(UInt32(pages.count)); b.appendLE(UInt32(0x2886_1667))
            var payload = [UInt8](page.text.utf8)
            payload += [UInt8](repeating: 0, count: 476 - payload.count)
            b += payload
            b.appendLE(UF2.magicEnd)
            out.append(contentsOf: b)
        }
        return out
    }

    @Test func namesTheFirmwareFromItsVersionString() {
        #expect(NRF52BackupStore.describe(image([(0x27000, "\0\0 junk"), (0xBA300, "\0 2.7.26.54e0d8d \0")])) == "Meshtastic 2.7.26 (54e0d8d)")
        #expect(NRF52BackupStore.describe(image([(0x82000, "xx\0v1.17.1-d929643\0yy")])) == "MeshCore v1.17.1 (d929643)")
        #expect(NRF52BackupStore.describe(image([(0x27000, "nothing here")])) == nil)
    }

    @Test func aBoardChangedToASmallerFirmwareReportsTheLeftovers() {
        let hybrid = image([(0x80800, "\0v1.17.1-d929643\0"), (0xBA300, "\02.7.26.54e0d8d\0")])
        #expect(NRF52BackupStore.describe(hybrid) == "MeshCore v1.17.1 (d929643), with leftovers of Meshtastic 2.7.26 (54e0d8d)")
    }

    @Test func listShowsWhatEachBackupHolds() throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        try NRF52BackupStore.save(image([(0x27000, "\02.7.26.54e0d8d\0")]), board: "Seeed TRACKER L1", in: dir)
        #expect(NRF52BackupStore.list(in: dir).first?.firmware == "Meshtastic 2.7.26 (54e0d8d)")
    }

    @Test func refusesToSaveSomethingThatIsNotAUF2() throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: UF2Error.self) { try NRF52BackupStore.save(Data("nope".utf8), board: "x", in: dir) }
        #expect(NRF52BackupStore.list(in: dir).isEmpty)
    }

    private func fakeVolume(current: Data?) throws -> (UF2Volume, URL) {
        let dir = try temporary()
        if let current { try current.write(to: dir.appendingPathComponent("CURRENT.UF2")) }
        return (UF2Volume(url: dir, model: "Seeed TRACKER L1", boardID: "TRACKER L1", bootloader: ""), dir)
    }

    @Test func anInstallSavesTheCurrentFirmwareFirst() async throws {
        let current = currentImage()
        let (volume, dir) = try fakeVolume(current: current)
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = Locked<[Data]>([])
        let flasher = UF2VolumeFlasher(volume: volume, image: UF2Tests.makeUF2(blocks: 4), onBackup: { saved.value.append($0) })
        #expect(flasher.steps.map(\.id) == ["verify", "backup", "write", "reboot"])
        try await flasher.run { _, _ in }
        #expect(saved.value == [current])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("NEW.UF2").path))
    }

    @Test func aFailedBackupStopsBeforeAnythingIsWritten() async throws {
        let (volume, dir) = try fakeVolume(current: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let flasher = UF2VolumeFlasher(volume: volume, image: UF2Tests.makeUF2(blocks: 4), onBackup: { _ in })
        await #expect(throws: UF2Error.self) { try await flasher.run { _, _ in } }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("NEW.UF2").path))
    }

    @Test func aSavedImageCanBeRestoredButNotInstalledAsFirmware() async throws {
        let image = currentImage()
        let (volume, dir) = try fakeVolume(current: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let asApplication = UF2VolumeFlasher(volume: volume, image: image)
        await #expect(throws: UF2Error.self) { try await asApplication.run { _, _ in } }
        let restore = UF2VolumeFlasher(volume: volume, image: image, content: .restore)
        #expect(restore.steps.map(\.id) == ["verify", "write", "reboot"])
        try await restore.run { _, _ in }
        #expect(try Data(contentsOf: dir.appendingPathComponent("NEW.UF2")) == image)
    }
}

@Suite struct FlashImageLabelTests {
    private func image(_ pieces: [(offset: Int, text: String)], size: Int = 4096) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: size)
        for piece in pieces { bytes.replaceSubrange(piece.offset..<piece.offset + piece.text.utf8.count, with: Array(piece.text.utf8)) }
        return Data(bytes)
    }

    @Test func namesTheFirmwareInAFullFlashImage() {
        #expect(FlashBackupStore.describe(image([(0x100, "\0v1.17.1-d929643\0")])) == "MeshCore v1.17.1 (d929643)")
        #expect(FlashBackupStore.describe(image([(0x200, "\0 2.7.26.54e0d8d\0")])) == "Meshtastic 2.7.26 (54e0d8d)")
        #expect(FlashBackupStore.describe(image([])) == nil)
    }

    @Test func aLaterOtherFirmwareIsReportedAsLeftover() {
        let label = FlashBackupStore.describe(image([(0x100, " v1.17.1-d929643 "), (0x800, " 2.7.26.54e0d8d ")]))
        #expect(label == "MeshCore v1.17.1 (d929643), with leftovers of Meshtastic 2.7.26 (54e0d8d)")
    }
}
