import Foundation
import Testing
@testable import MeshKitCore

@Suite struct FirmwareSourceTests {
    @Test(arguments: [
        ("agessaman/MeshCore", "agessaman/MeshCore"),
        ("https://github.com/agessaman/MeshCore", "agessaman/MeshCore"),
        ("github.com/agessaman/MeshCore.git", "agessaman/MeshCore"),
        ("https://github.com/agessaman/MeshCore/releases/tag/observer-mqtt-latest", "agessaman/MeshCore"),
        ("  a/b/ ", "a/b"),
    ])
    func acceptsProjectNames(input: String, expected: String) {
        #expect(FirmwareSource.normalize(input) == expected)
    }

    @Test(arguments: ["", "MeshCore", "a/", "/b", "a/b/c", "a b/c", "../x", "https://example.com/a/b", "a/../b"])
    func rejectsAnythingElse(input: String) {
        #expect(FirmwareSource.normalize(input) == nil)
    }

    @Test func nameDefaultsToTheProject() throws {
        #expect(try #require(FirmwareSource(repository: "agessaman/MeshCore")).name == "MeshCore")
        #expect(try #require(FirmwareSource(repository: "agessaman/MeshCore", name: " Observer ")).name == "Observer")
    }

    @Test func storeRoundTripsAndDropsDamagedEntries() throws {
        let defaults = try #require(UserDefaults(suiteName: "FirmwareSourceTests-\(UUID().uuidString)"))
        #expect(FirmwareSourceStore.load(defaults).isEmpty)
        let source = try #require(FirmwareSource(repository: "agessaman/MeshCore", name: "Observer"))
        FirmwareSourceStore.save([source], defaults)
        #expect(FirmwareSourceStore.load(defaults) == [source])
        defaults.set(Data(#"[{"repository":"../etc","name":"x"}]"#.utf8), forKey: FirmwareSourceStore.key)
        #expect(FirmwareSourceStore.load(defaults).isEmpty)
    }

    private func asset(_ name: String) -> GitHubAsset {
        GitHubAsset(id: abs(name.hashValue), name: name, size: 1, digest: nil, browserDownloadUrl: URL(string: "https://example.com/\(name)")!)
    }

    @Test func parsesDevBuildNames() throws {
        let a = try #require(FirmwareArtifact.parse(
            asset: asset("heltec_v4_repeater_observer_mqtt-v1.17.1.25-dev-a24dade.bin"), role: .repeater, releaseTag: "observer-mqtt-beta-latest"))
        #expect(a.board == "heltec_v4")
        #expect(a.variant == "repeater_observer_mqtt")
        #expect(a.version == "1.17.1.25-dev")
        #expect(a.commit == "a24dade")
        #expect(a.kind == .espAppImage)
        let merged = try #require(FirmwareArtifact.parse(
            asset: asset("Tbeam_SX1262_room_server_observer_mqtt-v1.17.1.25-dev-a24dade-merged.bin"), role: .roomServer, releaseTag: "t"))
        #expect(merged.kind == .espFullImage)
        #expect(merged.board == "Tbeam_SX1262")
    }

    @Test func aReleaseOfOneProjectHoldsEveryRole() throws {
        let release = GitHubRelease(tagName: "observer-mqtt-latest", name: nil, prerelease: true, publishedAt: nil, assets: [
            asset("heltec_v4_repeater_observer_mqtt-v1.17.1.4-c2c4cb5.bin"),
            asset("heltec_v4_repeater_observer_mqtt-v1.17.1.4-c2c4cb5-merged.bin"),
            asset("heltec_v4_room_server_observer_mqtt-v1.17.1.4-c2c4cb5-merged.bin"),
        ])
        let repeaters = ReleaseClient.builds(from: release, role: .repeater, source: "agessaman/MeshCore")
        #expect(repeaters.count == 1)
        #expect(repeaters[0].fullImage != nil)
        #expect(repeaters[0].artifacts.allSatisfy { $0.releaseTag == "agessaman/MeshCore-observer-mqtt-latest" })
        #expect(ReleaseClient.builds(from: release, role: .roomServer, source: "a/b").count == 1)
        #expect(ReleaseClient.builds(from: release, role: .companion, source: "a/b").isEmpty)
    }

    @Test func parsesForkVersionedNames() throws {
        let release = GitHubRelease(tagName: "mishmesh-v1.6.1", name: nil, prerelease: false, publishedAt: nil, assets: [
            asset("WioTrackerL1_companion_radio_ble_mishmesh_mm-v1.6.1_mc-v1.17.1-95eb491.uf2"),
            asset("WioTrackerL1_companion_radio_ble_mishmesh_mm-v1.6.1_mc-v1.17.1-95eb491.zip"),
            asset("WioTrackerL1_companion_radio_usb_mishmesh_mm-v1.6.1_mc-v1.17.1-95eb491.uf2"),
            asset("WioTrackerL1_companion_radio_usb_mishmesh_mm-v1.6.1_mc-v1.17.1-95eb491.zip"),
        ])
        let groups = FirmwareBoardGroup.groups(from: ReleaseClient.builds(from: release, role: .companion, source: "burakcan/MeshCore-mishmesh"))
        let wio = try #require(groups.first)
        #expect(groups.count == 1 && wio.board == "WioTrackerL1")
        #expect(Set(wio.connections) == [.usb, .ble])
        #expect(wio.builds.allSatisfy { $0.version == "1.6.1" && $0.fullImage?.kind == .uf2 })
    }
}
