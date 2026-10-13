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
}
