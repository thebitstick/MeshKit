import Foundation
import Testing
@testable import MeshKitCore

@Suite struct OTAFixTests {
    @Test func mapsMeshCoreAndMeshtasticBoardsToTheirBootloader() {
        #expect(OTAFix.boardID(meshCoreSlug: "Heltec_t114") == "heltec_t114")
        #expect(OTAFix.boardID(meshCoreSlug: "WioTrackerL1Eink") == "wio_tracker_l1")
        #expect(OTAFix.boardID(meshCoreSlug: "RAK_4631") == "wiscore_rak4631_board")
        #expect(OTAFix.boardID(meshtasticSlug: "seeed_wio_tracker_L1") == "wio_tracker_l1")
        #expect(OTAFix.boardID(meshtasticSlug: "rak4631") == "wiscore_rak4631_board")
        #expect(OTAFix.boardID(meshtasticSlug: "tracker-t1000-e") == "t1000_e")
    }

    @Test func readsTheInstalledBootloaderVersion() {
        #expect(OTAFix.installedVersion(inBootloader: "UF2 Bootloader 0.9.2-OTAFIX2.2-BP1.3 lib/nrfx (v2.0.0)") == "OTAFIX2.2-BP1.3")
        #expect(OTAFix.installedVersion(inBootloader: "UF2 Bootloader 0.9.2 lib/nrfx (v2.0.0)") == nil)
    }

    @Test func boardsWithoutAKnownBootloaderGetNone() {
        #expect(OTAFix.boardID(meshCoreSlug: "Heltec_v3") == nil)
        #expect(OTAFix.boardID(meshtasticSlug: "heltec-v3") == nil)
        #expect(OTAFix.boardID(meshCoreSlug: "GAT562_30S_Mesh_Kit") == nil)
    }

    private func bootloaderUpdate(blocks: Int = 4) -> Data {
        var out = Data()
        for i in 0..<blocks {
            var b: [UInt8] = []
            b.appendLE(UF2.magicStart0); b.appendLE(UF2.magicStart1); b.appendLE(UF2.familyFlag)
            b.appendLE(UInt32(i * 256)); b.appendLE(UInt32(256))
            b.appendLE(UInt32(i)); b.appendLE(UInt32(blocks)); b.appendLE(OTAFix.updateFamily)
            b += [UInt8](repeating: 0xBB, count: 476)
            b.appendLE(UF2.magicEnd)
            out.append(contentsOf: b)
        }
        return out
    }

    @Test func aBootloaderUpdateOnlyGoesThroughTheBootloaderPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("otafix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let volume = UF2Volume(url: dir, model: "m", boardID: "b", bootloader: "")
        let update = bootloaderUpdate()

        let asApp = UF2VolumeFlasher(volume: volume, image: update)
        await #expect(throws: UF2Error.self) { try await asApp.run { _, _ in } }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("NEW.UF2").path))

        let asApplicationInBootloaderMode = UF2VolumeFlasher(volume: volume, image: UF2Tests.makeUF2(blocks: 4), content: .bootloaderUpdate)
        await #expect(throws: UF2Error.self) { try await asApplicationInBootloaderMode.run { _, _ in } }

        let ok = UF2VolumeFlasher(volume: volume, image: update, content: .bootloaderUpdate)
        #expect(ok.steps.first?.title == "Check the bootloader update")
        try await ok.run { _, _ in }
        #expect(try Data(contentsOf: dir.appendingPathComponent("NEW.UF2")) == update)
    }
}
