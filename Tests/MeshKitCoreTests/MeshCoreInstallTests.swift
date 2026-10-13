import Foundation
import Testing
@testable import MeshKitCore

@Suite struct MeshCoreInstallTests {
    static func entry(_ name: String, type: UInt8, subtype: UInt8, offset: Int, size: Int) -> [UInt8] {
        var e: [UInt8] = [0xAA, 0x50, type, subtype]
        for v in [offset, size] { e += (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        e += Array(name.utf8) + [UInt8](repeating: 0, count: 16 - name.utf8.count)
        return e + [0, 0, 0, 0]
    }

    /// A merged image the way MeshCore publishes them: 64 KiB of bootloader, partition table and boot data, then the app.
    static func merged(chip: ESPChip = .esp32s3, appSize: Int = 100_000) -> [UInt8] {
        var image = [UInt8](repeating: 0xFF, count: 0x10000 + appSize)
        image[0] = 0xE9; image[12] = UInt8(chip.imageChipID & 0xFF); image[13] = UInt8(chip.imageChipID >> 8)
        var table: [UInt8] = []
        table += entry("nvs", type: 1, subtype: 2, offset: 0x9000, size: 0x5000)
        table += entry("otadata", type: 1, subtype: 0, offset: 0xE000, size: 0x2000)
        table += entry("app0", type: 0, subtype: 0x10, offset: 0x10000, size: 0x330000)
        table += entry("app1", type: 0, subtype: 0x11, offset: 0x340000, size: 0x330000)
        table += entry("spiffs", type: 1, subtype: 0x82, offset: 0x670000, size: 0x180000)
        image.replaceSubrange(0x8000..<(0x8000 + table.count), with: table)
        for i in 0xE000..<0x10000 { image[i] = 0x11 }
        image[0x10000] = 0xE9; image[0x10000 + 12] = UInt8(chip.imageChipID & 0xFF); image[0x10000 + 13] = UInt8(chip.imageChipID >> 8)
        for i in 0x10020..<image.count { image[i] = UInt8(truncatingIfNeeded: i) }
        return image
    }

    @Test func readsThePartitionTable() {
        let table = ESPPartitionTable.parse(image: Self.merged())
        #expect(table.map(\.name) == ["nvs", "otadata", "app0", "app1", "spiffs"])
        #expect(table[2] == ESPPartition(name: "app0", type: 0, subtype: 0x10, offset: 0x10000, size: 0x330000))
    }

    @Test func updateWritesOnlyBootDataAndTheApplication() throws {
        let image = Self.merged()
        let job = try MeshCoreImage.updateJob(merged: Data(image), name: "x.bin")
        #expect(!job.eraseAll)
        #expect(job.images.map(\.address) == [0xE000, 0x10000])
        #expect(job.images[0].data == Array(image[0xE000..<0x10000]) && !job.images[0].isApplication)
        #expect(job.images[1].data == Array(image[0x10000...]) && job.images[1].isApplication)
    }

    @Test func cleanInstallWritesTheWholeImageAfterErasing() {
        let image = Self.merged()
        let job = MeshCoreImage.cleanJob(merged: Data(image), name: "x.bin")
        #expect(job.eraseAll && job.images.count == 1 && job.images[0].address == 0 && job.images[0].data == image)
    }

    @Test func updateRefusesAnImageWithoutAReadableLayout() {
        var image = Self.merged()
        image[0x8000] = 0
        #expect(throws: MeshCoreInstallError.self) { try MeshCoreImage.updateJob(merged: Data(image), name: "x.bin") }
        #expect(throws: MeshCoreInstallError.self) { try MeshCoreImage.updateJob(merged: Data(), name: "x.bin") }
        var noApp = Self.merged()
        noApp[0x10000] = 0
        #expect(throws: MeshCoreInstallError.self) { try MeshCoreImage.updateJob(merged: Data(noApp), name: "x.bin") }
    }

    private func run(_ job: ESPFlashJob, on sim: SimulatedESPDevice) async throws {
        let flasher = ESPFlasher(portPath: "/dev/cu.usbserial-0001", job: job,
                                 options: ESPFlashOptions(baudRate: 921_600, useStub: true, backupFirst: false),
                                 openPort: { sim }, onBackup: nil)
        try await flasher.run { _, _ in }
    }

    @Test func anUpdateKeepsTheFilesystemAndACleanInstallWipesIt() async throws {
        let image = Self.merged()
        let identity = [UInt8](repeating: 0x5A, count: 4096)

        let updated = SimulatedESPDevice(chip: .esp32s3, flashSize: 8 << 20)
        updated.preload(identity, at: 0x670000)
        updated.preload([UInt8](repeating: 0x22, count: 0x2000), at: 0xE000)
        try await run(MeshCoreImage.updateJob(merged: Data(image), name: "x.bin"), on: updated)
        #expect(Array(updated.flashContents[0x670000..<(0x670000 + 4096)]) == identity)
        #expect(Array(updated.flashContents[0xE000..<image.count]) == Array(image[0xE000...]))

        let cleaned = SimulatedESPDevice(chip: .esp32s3, flashSize: 8 << 20)
        cleaned.preload(identity, at: 0x670000)
        try await run(MeshCoreImage.cleanJob(merged: Data(image), name: "x.bin"), on: cleaned)
        #expect(Array(cleaned.flashContents[0x670000..<(0x670000 + 4096)]) == [UInt8](repeating: 0xFF, count: 4096))
        #expect(Array(cleaned.flashContents[0..<image.count]) == image)
    }
}
