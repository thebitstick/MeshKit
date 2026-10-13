import Foundation
import Testing
@testable import MeshKitCore

/// Runs the whole pipeline against the newest published releases. Needs the network, so it only runs when
/// MESHKIT_NETWORK_TESTS=1.
@Suite struct LiveReleaseTests {
    private var enabled: Bool { ProcessInfo.processInfo.environment["MESHKIT_NETWORK_TESTS"] == "1" }

    @Test(arguments: MeshtasticChannel.allCases)
    func meshtasticReleaseInstallsWithoutDownloadingTheWholeZip(channel: MeshtasticChannel) async throws {
        guard enabled else { return }
        let catalog = MeshtasticCatalog()
        let release = try #require(try await catalog.releases(limit: 30).first { $0.channel == channel })
        let boards = try await catalog.boards(in: release)
        #expect(boards.count > 50)

        let heltec = try #require(boards.first { $0.slug == "heltec-v3" })
        #expect(heltec.displayName == "Heltec V3")
        let pkg = try catalog.package(for: heltec, in: release)
        let update = try await pkg.espJob(mode: .update)
        #expect(update.images.count == 1 && update.images[0].address == 0x10000 && !update.eraseAll)
        #expect(update.images[0].data.first == 0xE9)
        let fresh = try await pkg.espJob(mode: .fresh)
        #expect(fresh.eraseAll)
        #expect(fresh.images.map(\.address) == [0, 0x340000, 0x670000])
        #expect(fresh.images.last?.isApplication == false)
        try ESPImageCheck.validate(fresh.images[0].data, at: 0, chip: .esp32s3, flashSize: 8 << 20)
        #expect(throws: ESPError.self) { try ESPImageCheck.validate(fresh.images[0].data, at: 0, chip: .esp32c3, flashSize: 8 << 20) }

        let wio = try #require(boards.first { $0.slug == "seeed_wio_tracker_L1" })
        let uf2 = try await catalog.package(for: wio, in: release).uf2Image()
        #expect(try UF2.inspect(uf2).isNRF52)

        let dfu = try await NRF52DFUPackage.read(zip: try await catalog.package(for: wio, in: release).dfuPackage())
        #expect(dfu.firmware.count > 100_000 && !dfu.initPacket.isEmpty)

        let erase = try await catalog.nrf52EraseImages(in: release)
        #expect(erase.images.keys.sorted() == ["6.1", "7.3"])
        for image in erase.images.values { #expect(try UF2.inspect(image).isNRF52) }
    }

    @Test(arguments: MeshCoreRole.allCases)
    func meshCoreStableReleaseIsUnderstood(role: MeshCoreRole) async throws {
        guard enabled else { return }
        let release = try #require(try await ReleaseClient().releases(for: role, limit: 1).first)
        let firmwareAssets = release.assets.filter { ["bin", "uf2", "zip"].contains(($0.name as NSString).pathExtension) }
        #expect(!firmwareAssets.isEmpty)

        let artifacts = firmwareAssets.compactMap { FirmwareArtifact.parse(asset: $0, role: role, releaseTag: release.tagName) }
        let unparsed = firmwareAssets.filter { a in !artifacts.contains { $0.asset.id == a.id } }.map(\.name)
        #expect(unparsed.isEmpty, "not understood: \(unparsed)")

        let groups = FirmwareBoardGroup.groups(from: ReleaseClient.builds(from: release, role: role))
        #expect(groups.count > 20)
        let v3 = try #require(groups.first { $0.board.lowercased() == "heltec_v3" })
        #expect(v3.isESP32 && v3.builds.allSatisfy { $0.fullImage != nil })
        if role == .companion { #expect(Set(v3.connections) == [.usb, .ble]) }
        let wio = try #require(groups.first { $0.board == "WioTrackerL1" })
        #expect(wio.isUF2)
    }

    @Test func observerReleasesAreUnderstood() async throws {
        guard enabled else { return }
        let client = ReleaseClient(repository: "agessaman/MeshCore")
        let releases = try await client.releases(for: .repeater, limit: 8)
        let release = try #require(releases.first { $0.assets.count > 20 })
        let builds = ReleaseClient.builds(from: release, role: .repeater, source: client.repository)
        #expect(builds.count > 10)
        #expect(builds.allSatisfy { $0.fullImage != nil || $0.artifacts.contains { $0.kind == .espAppImage } })
        let v3 = try #require(FirmwareBoardGroup.groups(from: builds).first { $0.board.lowercased().hasPrefix("heltec_v") })
        #expect(v3.isESP32)
    }

    @Test func mishmeshReleasesOfferUSBAndBluetooth() async throws {
        guard enabled else { return }
        let client = ReleaseClient(repository: "burakcan/MeshCore-mishmesh")
        let release = try #require(try await client.releases(for: .companion, limit: 1).first)
        let groups = FirmwareBoardGroup.groups(from: ReleaseClient.builds(from: release, role: .companion, source: client.repository))
        let wio = try #require(groups.first { $0.board == "WioTrackerL1" })
        #expect(Set(wio.connections) == [.usb, .ble])
    }

    @Test(arguments: MeshCoreRole.allCases)
    func meshCoreUpdateKeepsTheApplicationIdenticalToTheAppOnlyFile(role: MeshCoreRole) async throws {
        guard enabled else { return }
        let client = ReleaseClient()
        let release = try #require(try await client.releases(for: role, limit: 1).first)
        let builds = ReleaseClient.builds(from: release, role: role)
        var checked = 0
        for board in ["heltec_v3", "xiao_c3", "heltec_v2", "lilygo_tdeck"] {
            let candidates = builds.filter { $0.board.lowercased() == board && (role != .companion || $0.variant.contains("usb")) }
            guard let build = candidates.first,
                  let merged = build.artifacts.first(where: { $0.kind == .espFullImage }),
                  let appOnly = build.artifacts.first(where: { $0.kind == .espAppImage }) else { continue }
            let mergedData = try await URLSession.shared.data(from: merged.asset.browserDownloadUrl).0
            let appData = try await URLSession.shared.data(from: appOnly.asset.browserDownloadUrl).0
            let job = try MeshCoreImage.updateJob(merged: mergedData, name: merged.asset.name)
            #expect(job.images.map(\.address) == [0xE000, 0x10000], "\(board) \(role)")
            #expect(job.images[1].data == [UInt8](appData), "\(board) \(role)")
            checked += 1
        }
        #expect(checked >= 2, "only \(checked) boards were checked")
    }

    @Test func everyMappedBoardHasABootloaderUpdateInTheLatestOTAFIXRelease() async throws {
        guard enabled else { return }
        let release = try await OTAFix.latestRelease()
        for id in OTAFix.boardIDs.sorted() { _ = try OTAFix.update(for: id, in: release) }
        let update = try OTAFix.update(for: "heltec_t114", in: release)
        let data = try Data(contentsOf: try await OTAFix.download(update))
        let info = try UF2.inspect(data)
        #expect(info.familyID == OTAFix.updateFamily && info.lowestAddress == 0)
    }
}
