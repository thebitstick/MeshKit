import Foundation
import MeshtasticProtobufs
import Testing
@testable import MeshKitCore

/// More real-board steps (see HardwareTests): MESHKIT_HARDWARE_STEP is one of `companion`, `room`, `meshtastic`,
/// `meshtastic-alpha`, each of which installs the firmware onto a Heltec V3 and then exercises it.
@Suite(.serialized) struct HardwareFirmwareTests {
    static func mergedImage(role: MeshCoreRole, usbCompanion: Bool = true) async throws -> (Data, String) {
        let client = ReleaseClient()
        let release = try #require(try await client.releases(for: role, limit: 1).first)
        let builds = ReleaseClient.builds(from: release, role: role)
        let build = try #require(builds.first { $0.board == "Heltec_v3" && (role != .companion || $0.variant.contains(usbCompanion ? "usb" : "ble")) })
        let artifact = try #require(build.artifacts.first { $0.kind == .espFullImage })
        return (try Data(contentsOf: try await client.download(artifact)), artifact.asset.name)
    }

    static func companion(_ path: String) async throws -> (CompanionClient, DeviceInfo, SelfInfo) {
        let transport = try HardwareTests.openPort(path)
        try await Task.sleep(for: .milliseconds(2500))
        let client = CompanionClient(transport: transport, logger: { print("  log:", $0) })
        await client.start()
        var lastError: Error = CompanionError.timeout
        for attempt in 1...12 {
            do {
                let (info, me) = try await client.handshake()
                if attempt > 1 { print("HANDSHAKE after \(attempt) attempts") }
                return (client, info, me)
            } catch { lastError = error; try await Task.sleep(for: .seconds(2)) }
        }
        throw lastError
    }

    @Test func meshCoreCompanion() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "companion" else { return }
        let (merged, name) = try await Self.mergedImage(role: .companion)
        print("IMAGE", name)
        try await HardwareTests.flash(MeshCoreImage.cleanJob(merged: merged, name: name), path: path)
        try await Task.sleep(for: .seconds(8))

        var (client, info, me) = try await Self.companion(path)
        print("INFO", info.model, info.semanticVersion, info.buildDate, "contacts<=", info.maxContacts)
        print("SELF", me.name, me.publicKeyHex.prefix(16), me.frequencyMHz, me.bandwidthKHz, me.spreadingFactor, me.codingRate, "tx", me.txPowerDBm, "max", me.maxTxPowerDBm)
        let original = me
        print("BATTERY", try await client.battery())
        print("TIME", try await client.deviceTime())

        try await client.setName("MeshKit Test")
        try await client.setRadio(frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5)
        try await client.setTxPower(max(2, original.txPowerDBm - 4))
        try await client.setLocation(latitude: 12.5, longitude: -45.25)
        try await client.syncClock()
        try await client.sendAdvert(flood: false)
        var (_, changed) = try await client.handshake()
        print("CHANGED", changed.name, changed.frequencyMHz, changed.bandwidthKHz, changed.spreadingFactor, changed.codingRate, changed.txPowerDBm, changed.latitude, changed.longitude)
        #expect(changed.name == "MeshKit Test" && abs(changed.frequencyMHz - 910.525) < 0.001 && changed.spreadingFactor == 7)
        #expect(abs(changed.latitude - 12.5) < 0.0001 && abs(changed.longitude + 45.25) < 0.0001)

        try await client.setName(original.name)
        try await client.setRadio(frequencyMHz: original.frequencyMHz, bandwidthKHz: original.bandwidthKHz, spreadingFactor: original.spreadingFactor, codingRate: original.codingRate)
        try await client.setTxPower(original.txPowerDBm)
        try await client.setLocation(latitude: original.latitude, longitude: original.longitude)
        (_, changed) = try await client.handshake()
        print("REVERTED", changed.name, changed.frequencyMHz, changed.txPowerDBm)
        #expect(changed.name == original.name && abs(changed.frequencyMHz - original.frequencyMHz) < 0.001 && changed.txPowerDBm == original.txPowerDBm)
        print("CONTACTS", try await client.contacts().count)

        try await client.reboot()
        await client.stop()
        try await Task.sleep(for: .seconds(6))
        (client, _, me) = try await Self.companion(path)
        print("AFTER REBOOT same key:", me.publicKey == original.publicKey, me.name)
        #expect(me.publicKey == original.publicKey)
        await client.stop()

        print("UPDATE (keeps identity)")
        try await HardwareTests.flash(try MeshCoreImage.updateJob(merged: merged, name: name), path: path)
        try await Task.sleep(for: .seconds(6))
        let (c2, _, me2) = try await Self.companion(path)
        print("AFTER UPDATE same key:", me2.publicKey == original.publicKey, me2.name)
        #expect(me2.publicKey == original.publicKey && me2.name == original.name)
        await c2.stop()
    }

    @Test func meshCoreRoomServer() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "room" else { return }
        let (merged, name) = try await Self.mergedImage(role: .roomServer)
        print("IMAGE", name)
        try await HardwareTests.flash(MeshCoreImage.cleanJob(merged: merged, name: name), path: path)
        try await Task.sleep(for: .seconds(8))

        var (cli, ident) = try await HardwareTests.repeater(path)
        print("IDENT", ident)
        let first = try await HardwareTests.snapshot(cli)
        for (k, v) in first.sorted(by: { $0.key < $1.key }) { print("SETTING \(k) = \(v)") }
        let name1 = try #require(CLICatalog.setting("name"))
        print("SET name ->", try await cli.write(name1, value: "Room Test"))
        print("TIME ->", try await cli.runChecked("time \(Int(Date().timeIntervalSince1970))"))
        print("ADVERT ->", try await cli.runChecked("advert"))
        for extra in ["neighbors", "clock", "get guest.password", "get public.key"] { print("CMD \(extra) ->", (try? await cli.run(extra)) ?? "(none)") }
        await cli.stop()

        print("UPDATE (keeps settings)")
        try await HardwareTests.flash(try MeshCoreImage.updateJob(merged: merged, name: name), path: path)
        try await Task.sleep(for: .seconds(6))
        (cli, ident) = try await HardwareTests.repeater(path)
        let after = try await HardwareTests.snapshot(cli)
        print("AFTER UPDATE", ident, after["name"] ?? "nil")
        #expect(after["name"] == "Room Test")
        await cli.stop()
    }

    static func meshtastic(_ path: String) async throws -> (MeshtasticClient, MeshtasticNodeState) {
        let transport = try HardwareTests.openPort(path)
        try await Task.sleep(for: .milliseconds(2500))
        let client = MeshtasticClient(transport: transport, logger: { print("  log:", $0) })
        guard await client.probe(timeout: 6) else { throw MeshtasticError.missingFile("no Meshtastic node answered") }
        return (client, try await client.connect())
    }

    @Test func meshtasticStableAndAlpha() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "meshtastic" else { return }
        let catalog = MeshtasticCatalog()
        let releases = try await catalog.releases(limit: 30)
        let stable = try #require(releases.first { $0.channel == .stable })
        let alpha = try #require(releases.first { $0.channel == .alpha })

        func install(_ release: MeshtasticRelease, _ mode: MeshtasticInstallMode) async throws {
            let board = try #require(try await catalog.boards(in: release).first { $0.slug == "heltec-v3" })
            let job = try await catalog.package(for: board, in: release).espJob(mode: mode)
            print("INSTALL", release.version, release.channel.rawValue, mode.rawValue, job.images.map { "\($0.name)@0x\(String($0.address, radix: 16))" })
            try await HardwareTests.flash(job, path: path)
            try await Task.sleep(for: .seconds(mode == .fresh ? 15 : 8))
        }

        try await install(stable, .fresh)
        var (client, state) = try await Self.meshtastic(path)
        print("STATE", state.nodeID, state.metadata?.firmwareVersion ?? "?", state.owner?.longName ?? "?", state.lora?.region ?? .unset, state.lora?.hopLimit ?? 0, state.channels.count, "nodes", state.nodes.count)
        #expect(state.metadata?.firmwareVersion.hasPrefix(stable.version.prefix(6)) == true)
        let id = state.nodeID
        try await client.apply(MeshtasticEdit(longName: "MeshKit Test", shortName: "MKT"))
        await client.stop()
        try await Task.sleep(for: .seconds(8))
        (client, state) = try await Self.meshtastic(path)
        print("RENAMED", state.owner?.longName ?? "?", state.owner?.shortName ?? "?")
        #expect(state.owner?.longName == "MeshKit Test")
        var lora = try #require(state.lora)
        let hop = lora.hopLimit
        lora.hopLimit = hop == 4 ? 5 : 4
        try await client.apply(MeshtasticEdit(lora: lora))
        await client.stop()
        try await Task.sleep(for: .seconds(8))
        (client, state) = try await Self.meshtastic(path)
        print("HOP", hop, "->", state.lora?.hopLimit ?? 0)
        #expect(state.lora?.hopLimit == lora.hopLimit)
        try await client.syncClock()
        await client.stop()

        try await install(alpha, .update)
        (client, state) = try await Self.meshtastic(path)
        print("ALPHA", state.metadata?.firmwareVersion ?? "?", state.owner?.longName ?? "?", state.nodeID == id)
        #expect(state.owner?.longName == "MeshKit Test" && state.nodeID == id)
        await client.stop()

        try await install(stable, .update)
        (client, state) = try await Self.meshtastic(path)
        print("BACK TO STABLE", state.metadata?.firmwareVersion ?? "?", state.owner?.longName ?? "?")
        await client.stop()
    }

    @Test func listen() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "listen" else { return }
        let transport = try SerialPort(path: path)
        let stream = transport.subscribe()
        let collector = Task { var all = Data(); for await chunk in stream { all.append(chunk) }; return all }
        try await Task.sleep(for: .seconds(6))
        print("QUIET BANNER", String(decoding: transport.isClosedPort ? Data() : Data(), as: UTF8.self))
        for attempt in 1...3 {
            try await transport.send(Data([0x3C, 0x02, 0x00, 0x16, 0x03]))
            try await Task.sleep(for: .seconds(2))
            print("ATTEMPT", attempt)
        }
        transport.close()
        let data = await collector.value
        print("HEARD", data.count, data.prefix(200).map { String(format: "%02x", $0) }.joined(), String(decoding: data.prefix(200), as: UTF8.self).debugDescription)
    }

    @Test func meshtasticAlphaDebug() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "alpha-debug" else { return }
        let catalog = MeshtasticCatalog()
        let alpha = try #require(try await catalog.releases(limit: 30).first { $0.channel == .alpha })
        var (client, state) = try await Self.meshtastic(path)
        print("BEFORE", state.nodeID, state.myInfo?.myNodeNum ?? 0, state.metadata?.firmwareVersion ?? "?")
        await client.stop()
        let board = try #require(try await catalog.boards(in: alpha).first { $0.slug == "heltec-v3" })
        try await HardwareTests.flash(try await catalog.package(for: board, in: alpha).espJob(mode: .update), path: path)
        try await Task.sleep(for: .seconds(10))
        (client, state) = try await Self.meshtastic(path)
        print("ALPHA", state.nodeID, state.myInfo?.myNodeNum ?? 0, state.metadata?.firmwareVersion ?? "?", "nodes", state.nodes.map { String(format: "!%08x", $0.num) + ":" + $0.user.longName })
        try await client.apply(MeshtasticEdit(longName: "Alpha Edit", shortName: "ALP"))
        await client.stop()
        try await Task.sleep(for: .seconds(8))
        (client, state) = try await Self.meshtastic(path)
        print("ALPHA AFTER EDIT", state.owner?.longName ?? "nil", state.nodeID)
        await client.stop()
    }

    /// Tries the MeshCore companion, the repeater console and Meshtastic in turn, the way the app does.
    @Test func whatIsRunning() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "what" else { return }
        let transport = try HardwareTests.openPort(path)
        try await Task.sleep(for: .milliseconds(2500))
        let mesh = MeshtasticClient(transport: transport, logger: { print("  log:", $0) })
        if await mesh.probe(timeout: 4), let state = try? await mesh.connect() {
            print("MESHTASTIC", state.nodeID, state.metadata?.firmwareVersion ?? "?", state.metadata?.hwModel ?? .unset, state.owner?.longName ?? "?")
            await mesh.stop(); return
        }
        await mesh.stop()
        let companion = CompanionClient(transport: transport, logger: { print("  log:", $0) })
        await companion.start()
        if let (info, me) = try? await companion.handshake() {
            print("COMPANION", info.model, info.semanticVersion, me.name, me.publicKeyHex.prefix(12))
            await companion.stop(); return
        }
        await companion.stop()
        let cli = RepeaterCLIClient(transport: transport, logger: { print("  log:", $0) })
        await cli.start()
        print("CLI", try await cli.identify())
        await cli.stop()
    }

    @Test func nrfBackup() async throws {
        guard HardwareTests.step == "nrf-backup" else { return }
        let v = try #require(UF2Volumes.detect().first)
        print("VOLUME", v.name, v.model, v.boardID, v.softDevice, v.bootloader.prefix(60))
        let current = try UF2Flasher.readCurrentImage(from: v)
        try current.write(to: HardwareTests.out.appendingPathComponent("wio-current.uf2"))
        let info = try UF2.inspect(current)
        print("CURRENT.UF2", current.count, info.familyName, String(info.lowestAddress, radix: 16), String(info.highestAddress, radix: 16), "payload", info.payloadBytes)
    }

    static func nrfVolume() throws -> UF2Volume { try #require(UF2Volumes.detect().first) }

    static func meshCoreUF2(role: MeshCoreRole, board: String, variantContains: String? = nil) async throws -> (Data, String) {
        let client = ReleaseClient()
        let release = try #require(try await client.releases(for: role, limit: 1).first)
        let builds = ReleaseClient.builds(from: release, role: role)
        let build = try #require(builds.first { $0.board == board && (variantContains == nil || $0.variant.contains(variantContains!)) })
        let artifact = try #require(build.artifacts.first { $0.kind == .uf2 })
        return (try Data(contentsOf: try await client.download(artifact)), artifact.asset.name)
    }

    static func nrfFlash(_ image: Data, erase: NRF52EraseImages? = nil) async throws {
        let volume = try nrfVolume()
        print("FLASHING to", volume.name, volume.softDevice, "erase:", erase != nil)
        let flasher = UF2VolumeFlasher(volume: volume, image: image, erase: erase)
        try await flasher.run { id, state in
            switch state {
            case .done: print("  step \(id): done")
            case .failed(let m): print("  step \(id): FAILED \(m)")
            case .running(let p?): if Int(p * 100) % 50 == 0 { print("  step \(id): \(Int(p * 100))%") }
            default: break
            }
        }
    }

    static func waitForPort(_ path: String, seconds: Int = 40) async throws {
        for _ in 0..<(seconds * 2) {
            if FileManager.default.fileExists(atPath: path) { try await Task.sleep(for: .seconds(1)); return }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("PORT NEVER APPEARED", path)
    }

    @Test func nrfCompanionInstall() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "nrf-companion" else { return }
        let (image, name) = try await Self.meshCoreUF2(role: .companion, board: "WioTrackerL1", variantContains: "usb")
        print("IMAGE", name, image.count)
        try await Self.nrfFlash(image)
        try await Self.waitForPort(path)
        try await Task.sleep(for: .seconds(4))
        print("PORTS", SerialDiscovery.list().map(\.path))
        let (client, info, me) = try await Self.companion(path)
        print("INFO", info.model, info.semanticVersion, "SELF", me.name, me.publicKeyHex.prefix(12), me.frequencyMHz, me.txPowerDBm, "max", me.maxTxPowerDBm)
        print("BATTERY", try await client.battery())
        try await client.setName("Wio Test")
        let (_, changed) = try await client.handshake()
        print("RENAMED", changed.name)
        #expect(changed.name == "Wio Test")
        try await client.setName(me.name)
        await client.stop()
        HardwareTests.closePorts()
    }

    static func waitForVolume(seconds: Int = 420) async throws {
        print("WAITING FOR THE UF2 DRIVE (double-tap reset)")
        for _ in 0..<(seconds * 2) {
            if !UF2Volumes.detect().isEmpty { try await Task.sleep(for: .seconds(1)); return }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("no UF2 drive appeared")
    }

    static func eraseImages() async throws -> NRF52EraseImages {
        let catalog = MeshtasticCatalog()
        let release = try #require(try await catalog.releases(limit: 30).first { $0.channel == .stable })
        return try await catalog.nrf52EraseImages(in: release)
    }

    @Test func nrfCleanCompanion() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "nrf-clean-companion" else { return }
        try await Self.waitForVolume()
        let (image, name) = try await Self.meshCoreUF2(role: .companion, board: "WioTrackerL1", variantContains: "usb")
        print("IMAGE", name)
        try await Self.nrfFlash(image, erase: try await Self.eraseImages())
        try await Self.waitForPort(path)
        try await Task.sleep(for: .seconds(4))
        let (client, info, me) = try await Self.companion(path)
        print("CLEAN INFO", info.semanticVersion, "SELF", me.name, me.publicKeyHex.prefix(12), "(before: 6ea6c6b08663)")
        #expect(!me.publicKeyHex.hasPrefix("6ea6c6b08663"))
        await client.stop()
        HardwareTests.closePorts()
    }

    @Test func nrfMeshtasticClean() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "nrf-meshtastic-clean" else { return }
        try await Self.waitForVolume()
        let catalog = MeshtasticCatalog()
        let release = try #require(try await catalog.releases(limit: 30).first { $0.channel == .stable })
        let board = try #require(try await catalog.boards(in: release).first { $0.slug == "seeed_wio_tracker_L1" })
        let image = try await catalog.package(for: board, in: release).uf2Image()
        print("IMAGE", board.displayName, release.version, image.count)
        try await Self.nrfFlash(image, erase: try await catalog.nrf52EraseImages(in: release))
        try await Self.waitForPort(path)
        try await Task.sleep(for: .seconds(8))
        var (client, state) = try await Self.meshtastic(path)
        print("MT STATE", state.nodeID, state.metadata?.firmwareVersion ?? "?", state.metadata?.hwModel ?? .unset, state.owner?.longName ?? "?", state.lora?.region ?? .unset)
        try await client.apply(MeshtasticEdit(longName: "Wio Mesh Test", shortName: "WMT"))
        await client.stop()
        try await Task.sleep(for: .seconds(8))
        (client, state) = try await Self.meshtastic(path)
        print("MT RENAMED", state.owner?.longName ?? "?")
        #expect(state.owner?.longName == "Wio Mesh Test")
        await client.stop()
        HardwareTests.closePorts()
    }

    @Test func nrfBootloaderFix() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "nrf-dfu" else { return }
        try await Self.waitForVolume()
        let before = try Self.nrfVolume()
        print("BOOTLOADER BEFORE", before.bootloader.prefix(40))
        let id = try #require(OTAFix.boardID(meshCoreSlug: "WioTrackerL1"))
        let update = try await OTAFix.latestUpdate(for: id)
        print("UPDATE", update.tag, update.asset.name)
        let data = try Data(contentsOf: try await OTAFix.download(update))
        let flasher = UF2VolumeFlasher(volume: before, image: data, content: .bootloaderUpdate)
        try await flasher.run { step, state in print("  step \(step): \(state)") }
        try await Task.sleep(for: .seconds(8))
        print("VOLUMES AFTER", UF2Volumes.detect().map { "\($0.name) \($0.bootloader.prefix(40))" }, "PORTS", SerialDiscovery.list().map(\.path))
        try await Self.waitForPort(path)
    }

    @Test func listenOnly() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "listen-only" else { return }
        let transport = try HardwareTests.openPort(path)
        let stream = transport.subscribe()
        let collector = Task { var all = Data(); for await chunk in stream { all.append(chunk) }; return all }
        try await Task.sleep(for: .seconds(5))
        HardwareTests.closePorts()
        let data = await collector.value
        print("HEARD", data.count, String(decoding: data.prefix(400), as: UTF8.self).debugDescription)
    }

    @Test func nrfRestoreOriginal() async throws {
        guard HardwareTests.step == "nrf-restore" else { return }
        try await Self.waitForVolume()
        let v = try Self.nrfVolume()
        print("BOOTLOADER NOW", v.bootloader.prefix(45), "installed:", OTAFix.installedVersion(inBootloader: v.bootloader) ?? "none")
        let original = try Data(contentsOf: HardwareTests.out.appendingPathComponent("wio-current.uf2"))
        print("RESTORING", original.count)
        let outcome = try await UF2Flasher.flash(image: original, to: v) { _ in }
        print("OUTCOME", outcome)
    }

    @Test func nrfAdminDFU() async throws {
        guard let path = HardwareTests.port, HardwareTests.step == "nrf-admin-dfu" else { return }
        try await Self.waitForVolume()
        let catalog = MeshtasticCatalog()
        let release = try #require(try await catalog.releases(limit: 30).first { $0.channel == .stable })
        let board = try #require(try await catalog.boards(in: release).first { $0.slug == "seeed_wio_tracker_L1" })
        try await Self.nrfFlash(try await catalog.package(for: board, in: release).uf2Image())
        try await Self.waitForPort(path)
        try await Task.sleep(for: .seconds(8))
        let (client, state) = try await Self.meshtastic(path)
        print("MT UP", state.nodeID, state.metadata?.firmwareVersion ?? "?")
        try await client.enterDFUMode()
        await client.stop()
        HardwareTests.closePorts()
        for _ in 0..<40 {
            if let v = UF2Volumes.detect().first { print("ADMIN DFU WORKS ->", v.name, v.bootloader.prefix(40)); return }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("ADMIN DFU DID NOT PRODUCE A DRIVE; ports", SerialDiscovery.list().map(\.path))
    }
}
