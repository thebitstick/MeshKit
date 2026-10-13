import Foundation
import Testing
@testable import MeshKitCore

@Suite struct NRF52EraseTests {
    private let infoText = "UF2 Bootloader 0.9.2\nModel: Seeed Wio Tracker L1\nBoard-ID: nRF52840-WioTrackerL1-v1\nSoftDevice: S140 7.3.0\n"

    @Test func readsTheSoftDeviceFromTheBootloaderInfo() {
        let v = UF2Volumes.parse(infoText: infoText, url: URL(fileURLWithPath: "/Volumes/WIOBOOT"))
        #expect(v.softDevice == "S140 7.3.0")
    }

    @Test func picksTheEraseFileForTheBoardsSoftDevice() {
        let images = NRF52EraseImages(images: ["7.3": Data([7]), "6.1": Data([6])])
        func volume(_ sd: String) -> UF2Volume { UF2Volume(url: URL(fileURLWithPath: "/x"), model: "m", boardID: "b", bootloader: "", softDevice: sd) }
        #expect(images.image(for: volume("S140 7.3.0")) == Data([7]))
        #expect(images.image(for: volume("S140 6.1.1")) == Data([6]))
        #expect(images.image(for: volume("S140 7.9.0")) == nil)
        #expect(images.image(for: volume("")) == nil)
    }

    @Test func cleanInstallErasesWaitsForTheDriveToReturnThenInstalls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erasetest-\(UUID().uuidString)")
        let first = root.appendingPathComponent("BOOT"), second = root.appendingPathComponent("BOOT2")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func writeInfo(_ dir: URL) throws { try infoText.write(to: dir.appendingPathComponent("INFO_UF2.TXT"), atomically: true, encoding: .utf8) }
        try writeInfo(first)

        let eraseImage = UF2Tests.makeUF2(blocks: 8), firmware = UF2Tests.makeUF2(blocks: 40)
        let volume = UF2Volumes.parse(infoText: infoText, url: first)

        let received = Locked<[Data]>([])
        let poked = Locked<[String]>([])
        let board = Task {
            for dir in [first, second] {
                let file = dir.appendingPathComponent("NEW.UF2")
                let expected = dir == first ? eraseImage.count : firmware.count
                while !((try? Data(contentsOf: file).count) == expected) { try await Task.sleep(for: .milliseconds(20)) }
                received.value.append(try Data(contentsOf: file))
                try FileManager.default.removeItem(at: dir)
                if dir == first {
                    while poked.value.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
                    try writeInfo(second)
                }
            }
        }

        let flasher = UF2VolumeFlasher(volume: volume, image: firmware, erase: NRF52EraseImages(images: ["7.3": eraseImage]),
                                       findVolumes: { UF2Volumes.detect(volumesRoot: root) },
                                       candidatePorts: { ["/dev/cu.usbmodemFAKE"] },
                                       holdPort: { path, _ in poked.value.append(path); try? await Task.sleep(for: .milliseconds(50)) },
                                       returnTimeout: .seconds(10))
        #expect(flasher.steps.map(\.id) == ["verify", "erase", "return", "write", "reboot"])
        let states = Locked<[String: FlashStep.State]>([:])
        try await flasher.run { id, state in states.value[id] = state }
        try await board.value

        #expect(received.value == [eraseImage, firmware])
        #expect(poked.value.first == "/dev/cu.usbmodemFAKE")
        for id in ["verify", "erase", "return", "write", "reboot"] { #expect(states.value[id] == FlashStep.State.done, "\(id)") }
    }

    @Test func refusesACleanInstallWhenNoEraseFileMatchesTheBootloader() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("erasetest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let volume = UF2Volume(url: dir, model: "m", boardID: "b", bootloader: "", softDevice: "S140 9.0.0")
        let flasher = UF2VolumeFlasher(volume: volume, image: UF2Tests.makeUF2(blocks: 4), erase: NRF52EraseImages(images: ["7.3": UF2Tests.makeUF2(blocks: 2)]))
        await #expect(throws: UF2Error.self) { try await flasher.run { _, _ in } }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("NEW.UF2").path))
    }
}
