import Foundation
import MeshtasticProtobufs
import SwiftProtobuf
import Testing
@testable import MeshKitCore

@Suite struct MeshtasticFramingTests {
    @Test func framesWithBigEndianLength() {
        let wire = [UInt8](MeshtasticStream.frame([1, 2, 3]))
        #expect(wire == [0x94, 0xC3, 0x00, 0x03, 1, 2, 3])
        let long = [UInt8](MeshtasticStream.frame([UInt8](repeating: 7, count: 300)))
        #expect(Array(long[0..<4]) == [0x94, 0xC3, 0x01, 0x2C])
    }

    @Test func decodesAcrossChunksAndSkipsLogLines() {
        var d = MeshtasticFrameDecoder()
        let log = Data("DEBUG | 12:00:01 5 [Router] Received text msg\r\n".utf8)
        let wire = MeshtasticStream.frame([9, 8, 7]) + MeshtasticStream.frame([1])
        #expect(d.feed(log).isEmpty)
        #expect(d.feed(wire.prefix(3)).isEmpty)
        #expect(d.feed(wire.dropFirst(3)) == [[9, 8, 7], [1]])
        #expect(d.discardedBytes > 0)
    }

    @Test func wakeBytesAndRunsOfStart1DoNotBreakSync() {
        var d = MeshtasticFrameDecoder()
        let junk = Data(repeating: 0xC3, count: 32) + Data(repeating: 0x94, count: 5)
        #expect(d.feed(junk + MeshtasticStream.frame([5, 5])) == [[5, 5]])
    }

    @Test func oversizeLengthResynchronises() {
        var d = MeshtasticFrameDecoder()
        let bad = Data([0x94, 0xC3, 0x10, 0x00])                // 4096 > 512
        #expect(d.feed(bad + MeshtasticStream.frame([4])) == [[4]])
    }
}

@Suite struct MeshtasticClientTests {
    private func connected() async throws -> (MeshtasticClient, SimulatedMeshtasticNode) {
        let node = SimulatedMeshtasticNode()
        let client = MeshtasticClient(transport: node)
        await client.start()
        _ = try await client.connect(timeout: 5)
        return (client, node)
    }

    @Test func handshakeCollectsIdentityConfigChannelsAndNodes() async throws {
        let (client, _) = try await connected()
        let s = await client.state
        #expect(s.myNodeNum == 0x1234_ABCD)
        #expect(s.nodeID == "!1234abcd")
        #expect(s.metadata?.firmwareVersion == "2.7.26.54e0d8d")
        #expect(s.owner?.longName == "Demo Node")
        #expect(s.lora?.region == .us)
        #expect(s.lora?.modemPreset == .longFast)
        #expect(s.device?.role == .client)
        #expect(s.channels.count == 8)
        #expect(s.channels[0].role == .primary)
        #expect(s.nodes.count == 3)
        await client.stop()
    }

    @Test func probeRecognisesANodeAndRejectsSilence() async throws {
        let node = SimulatedMeshtasticNode()
        let c = MeshtasticClient(transport: node)
        #expect(await c.probe(timeout: 1))
        await c.stop()

        final class Silent: ByteTransport, @unchecked Sendable {
            let b = DataBroadcaster()
            func subscribe() -> AsyncStream<Data> { b.subscribe() }
            func send(_ data: Data) async throws {}
            func close() {}
        }
        let quiet = MeshtasticClient(transport: Silent())
        #expect(await quiet.probe(timeout: 0.3) == false)
        await quiet.stop()
    }

    @Test func editsApplyThroughASessionKeyedTransaction() async throws {
        let (client, node) = try await connected()
        var lora = try #require(await client.state.lora)
        lora.region = .eu868
        lora.modemPreset = .mediumFast
        lora.hopLimit = 5
        var device = try #require(await client.state.device)
        device.role = .router

        try await client.apply(MeshtasticEdit(longName: "Hilltop Router", shortName: "HILLTOP", lora: lora, device: device))

        #expect(node.currentOwner.longName == "Hilltop Router")
        #expect(node.currentOwner.shortName == "HILL")
        #expect(node.currentLoRa.region == .eu868)
        #expect(node.currentLoRa.modemPreset == .mediumFast)
        #expect(node.currentLoRa.hopLimit == 5)
        #expect(node.currentDevice.role == .router)
        #expect(node.committedTransactions == 1)
        #expect(node.rejectedAdminMessages == 0)
        await client.stop()
    }

    private func rawSetOwner(_ name: String, from: UInt32, key: Data = Data(), id: UInt32 = 77) throws -> Data {
        var admin = AdminMessage(); admin.setOwner = User.with { $0.longName = name }; admin.sessionPasskey = key
        var packet = MeshPacket()
        packet.from = from; packet.to = 0x1234_ABCD; packet.id = id; packet.wantAck = true
        packet.decoded = DataMessage.with { $0.portnum = .adminApp; $0.payload = (try? admin.serializedData()) ?? Data() }
        return MeshtasticStream.frame([UInt8](try ToRadio.with { $0.packet = packet }.serializedData()))
    }

    @Test func localWritesNeedNoSessionKeyButRemoteOriginWritesDo() async throws {
        // Matches the firmware: the key check only applies to packets with from != 0.
        let node = SimulatedMeshtasticNode()
        try await node.send(try rawSetOwner("Local Name", from: 0))
        #expect(node.currentOwner.longName == "Local Name")
        #expect(node.rejectedAdminMessages == 0)

        var incoming = node.subscribe().makeAsyncIterator()
        try await node.send(try rawSetOwner("Remote Intruder", from: 0xBEEF, id: 91))
        #expect(node.currentOwner.longName == "Local Name")
        #expect(node.rejectedAdminMessages == 1)
        var decoder = MeshtasticFrameDecoder()
        let chunk = try #require(await incoming.next())
        let frame = try #require(decoder.feed(chunk).first)
        let fromRadio = try FromRadio(serializedBytes: frame)
        guard case .packet(let p)? = fromRadio.payloadVariant, case .decoded(let d)? = p.payloadVariant else {
            Issue.record("expected a packet"); return
        }
        #expect(d.requestID == 91)
        #expect(try Routing(serializedBytes: [UInt8](d.payload)).errorReason == .adminBadSessionKey)
    }

    @Test func managedNodesIgnoreLocalAdminAndTheClientSaysSo() async throws {
        let (client, node) = try await connected()
        node.setManaged(true)
        _ = try await client.connect(timeout: 5)          // re-read so the client sees is_managed
        await #expect(throws: MeshtasticNodeError.managed) { try await client.apply(MeshtasticEdit(longName: "Nope")) }
        #expect(node.currentOwner.longName == "Demo Node")
        await client.stop()
    }

    @Test func rebootNeedsTheKeyToo() async throws {
        let (client, node) = try await connected()
        try await client.reboot(seconds: 7)
        try await Task.sleep(for: .milliseconds(100))
        #expect(node.rebootRequests == [7])
        await client.stop()
    }

    @Test func aNodeCanBeToldToRestartIntoItsBootloader() async throws {
        let (client, node) = try await connected()
        try await client.enterDFUMode()
        try await Task.sleep(for: .milliseconds(100))
        #expect(node.dfuRequests == 1)
        node.setManaged(true)
        _ = try await client.connect(timeout: 5)
        await #expect(throws: MeshtasticNodeError.managed) { try await client.enterDFUMode() }
        await client.stop()
    }

    @Test func notAMeshtasticNodeFailsCleanly() async throws {
        final class Chatty: ByteTransport, @unchecked Sendable {
            let b = DataBroadcaster()
            func subscribe() -> AsyncStream<Data> { b.subscribe() }
            func send(_ data: Data) async throws { b.yield(Data("ERROR: unknown command\r\n".utf8)) }
            func close() {}
        }
        let client = MeshtasticClient(transport: Chatty())
        await #expect(throws: MeshtasticNodeError.self) { _ = try await client.connect(timeout: 0.5) }
        await client.stop()
    }
}

@Suite struct MeshtasticSettingsTests {
    private func state() async throws -> MeshtasticNodeState {
        let client = MeshtasticClient(transport: SimulatedMeshtasticNode())
        await client.start()
        let s = try await client.connect(timeout: 5)
        await client.stop()
        return s
    }

    @Test func labelsReadNaturally() {
        #expect(MeshtasticLabels.region(.eu868) == "EU 868")
        #expect(MeshtasticLabels.region(.us) == "US")
        #expect(MeshtasticLabels.region(.anz433) == "ANZ 433")
        #expect(MeshtasticLabels.region(.unset) == "Not set")
        #expect(MeshtasticLabels.modemPreset(.longFast) == "Long Fast")
        #expect(MeshtasticLabels.modemPreset(.shortTurbo) == "Short Turbo")
        #expect(MeshtasticLabels.role(.clientMute) == "Client Mute")
        #expect(MeshtasticLabels.keySummary(Data([1])) == "Default key")
        #expect(MeshtasticLabels.keySummary(Data(repeating: 0, count: 32)) == "AES-256 key")
        for r in Config.LoRaConfig.RegionCode.allCases { #expect(!MeshtasticLabels.region(r).isEmpty) }
        for p in Config.LoRaConfig.ModemPreset.allCases { #expect(!MeshtasticLabels.modemPreset(p).isEmpty) }
    }

    @Test func snapshotAndEditRoundTrip() async throws {
        let s = try await state()
        let values = MeshtasticValues.snapshot(of: s)
        #expect(values["owner.long"] == "Demo Node")
        #expect(values["lora.region"] == String(Config.LoRaConfig.RegionCode.us.rawValue))

        #expect(MeshtasticValues.edit(from: values, current: s).isEmpty)

        var changed = values
        changed["lora.region"] = String(Config.LoRaConfig.RegionCode.eu868.rawValue)
        changed["lora.hop"] = "6"
        changed["device.role"] = String(Config.DeviceConfig.Role.router.rawValue)
        changed["owner.long"] = "Renamed"
        let edit = MeshtasticValues.edit(from: changed, current: s)
        #expect(edit.longName == "Renamed")
        #expect(edit.shortName == nil)
        #expect(edit.lora?.region == .eu868 && edit.lora?.hopLimit == 6)
        #expect(edit.device?.role == .router)
    }

    @Test func restoreToASimulatedNodeAppliesTheSnapshot() async throws {
        let node = SimulatedMeshtasticNode()
        let client = MeshtasticClient(transport: node)
        await client.start()
        let s = try await client.connect(timeout: 5)
        var values = MeshtasticValues.snapshot(of: s)
        values["lora.region"] = String(Config.LoRaConfig.RegionCode.anz.rawValue)
        values["owner.long"] = "Restored Node"
        try await client.apply(MeshtasticValues.edit(from: values, current: s))
        #expect(node.currentLoRa.region == .anz)
        #expect(node.currentOwner.longName == "Restored Node")
        await client.stop()
    }
}
