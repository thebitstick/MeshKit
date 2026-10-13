import Foundation
import Testing
@testable import MeshKitCore

@Suite struct FramingTests {
    @Test func roundTrip() {
        var d = FrameDecoder(marker: USBFrame.toRadioMarker)
        let frames = d.feed(USBFrame.encode([1, 2, 3]) + USBFrame.encode([9]))
        #expect(frames == [[1, 2, 3], [9]])
    }

    @Test func splitAcrossChunks() {
        var d = FrameDecoder()
        let wire = USBFrame.encode([5, 6, 7, 8], marker: USBFrame.fromRadioMarker)
        #expect(d.feed(wire.prefix(2)).isEmpty)
        #expect(d.feed(wire.dropFirst(2).prefix(2)).isEmpty)
        #expect(d.feed(wire.dropFirst(4)) == [[5, 6, 7, 8]])
    }

    @Test func skipsDebugNoiseBeforeFrame() {
        var d = FrameDecoder()
        let noise = Data("boot: hello\r\n".utf8)
        let out = d.feed(noise + USBFrame.encode([0], marker: USBFrame.fromRadioMarker))
        #expect(out == [[0]])
        #expect(d.discardedBytes > 0)
    }

    @Test func resyncsOnImpossibleLength() {
        var d = FrameDecoder()
        let out = d.feed(Data([0x3E, 0xFF, 0xFF]) + USBFrame.encode([42], marker: USBFrame.fromRadioMarker))
        #expect(out == [[42]])
    }
}

@Suite struct CompanionCodecTests {
    @Test func selfInfoRoundTrip() throws {
        let info = SelfInfo(advType: .repeater, txPowerDBm: 17, maxTxPowerDBm: 22, publicKey: Array(0..<32),
                            latitude: 51.5074, longitude: -0.1278, multiAcks: true, advertLocationShared: true,
                            telemetryModes: 5, manualAddContacts: false, frequencyMHz: 869.618, bandwidthKHz: 62.5,
                            spreadingFactor: 8, codingRate: 8, name: "Test Node")
        guard case .selfInfo(let parsed) = try CompanionResponse.parse(info.encode()) else { Issue.record("wrong case"); return }
        #expect(parsed == info)
    }

    @Test func contactRoundTrip() throws {
        let c = Contact(publicKey: Array(repeating: 7, count: 32), type: .room, flags: 1, outPathLength: -1, name: "Room",
                        lastAdvert: Date(timeIntervalSince1970: 1_700_000_000), latitude: 1.5, longitude: -2.5,
                        lastModified: Date(timeIntervalSince1970: 1_700_000_100))
        guard case .contact(let parsed) = try CompanionResponse.parse(c.encode()) else { Issue.record("wrong case"); return }
        #expect(parsed == c)
    }

    @Test func deviceInfoParsesFixedFields() throws {
        let info = DeviceInfo(firmwareVersion: 9, maxContacts: 350, maxChannels: 8, blePin: 123_456,
                              buildDate: "19 Feb 2025", model: "Heltec V3", semanticVersion: "v1.17.1")
        guard case .deviceInfo(let parsed) = try CompanionResponse.parse(info.encode()) else { Issue.record("wrong case"); return }
        #expect(parsed == info)
    }

    @Test func oldDeviceInfoWithoutV3FieldsStillParses() throws {
        guard case .deviceInfo(let parsed) = try CompanionResponse.parse([13, 1]) else { Issue.record("wrong case"); return }
        #expect(parsed.firmwareVersion == 1)
        #expect(parsed.model.isEmpty)
    }

    @Test func truncatedSelfInfoThrows() {
        #expect(throws: ProtocolError.self) { try CompanionResponse.parse([5, 1, 2, 3]) }
    }

    @Test func pushAndUnknownCodes() throws {
        #expect(try CompanionResponse.parse([0x83]) == .push(code: 0x83, payload: []))
        #expect(try CompanionResponse.parse([99, 1]) == .unknown(code: 99, payload: [1]))
    }

    @Test func radioParamsEncoding() {
        let p = CompanionRequest.setRadioParams(frequencyMHz: 869.525, bandwidthKHz: 250, spreadingFactor: 11, codingRate: 5)
        let expected: [UInt8] = [11, 0x95, 0x44, 0x0D, 0x00, 0x90, 0xD0, 0x03, 0x00, 11, 5]
        #expect(p == expected)
    }

    @Test func advertNameIsTruncated() {
        let p = CompanionRequest.setAdvertName(String(repeating: "x", count: 100))
        #expect(p.count == 1 + 31)
    }
}

@Suite struct CompanionClientTests {
    @Test func handshakeAgainstSimulator() async throws {
        let transport = SimulatedCompanionTransport(name: "Unit")
        let client = CompanionClient(transport: transport)
        await client.start()
        let (info, me) = try await client.handshake()
        #expect(info.semanticVersion == "v1.17.1")
        #expect(me.name == "Unit")
        #expect(me.frequencyMHz == 910.525)
        await client.stop()
    }

    @Test func contactsAndSettersRoundTrip() async throws {
        let client = CompanionClient(transport: SimulatedCompanionTransport())
        await client.start()
        let contacts = try await client.contacts()
        #expect(contacts.count == 5)

        try await client.setName("Renamed")
        try await client.setRadio(frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8)
        try await client.setTxPower(10)
        let (_, me) = try await client.handshake()
        #expect(me.name == "Renamed")
        #expect(me.frequencyMHz == 869.618)
        #expect(me.bandwidthKHz == 62.5)
        #expect(me.spreadingFactor == 8)
        #expect(me.txPowerDBm == 10)
        await client.stop()
    }

    @Test func concurrentRequestsAreSerialized() async throws {
        let client = CompanionClient(transport: SimulatedCompanionTransport())
        await client.start()
        async let a = client.battery()
        async let b = client.deviceTime()
        async let c = client.stats(2)
        let (battery, _, stats) = try await (a, b, c)
        #expect(battery.millivolts == 3920)
        if case .packets(let rx, _, _, _, _, _) = stats { #expect(rx == 1204) } else { Issue.record("wrong stats") }
        await client.stop()
    }

    @Test func timesOutOnSilence() async throws {
        final class Silent: ByteTransport, @unchecked Sendable {
            let b = DataBroadcaster()
            func subscribe() -> AsyncStream<Data> { b.subscribe() }
            func send(_ data: Data) async throws {}
            func close() {}
        }
        let client = CompanionClient(transport: Silent())
        await client.start()
        await #expect(throws: CompanionError.timeout) {
            _ = try await client.request([5], timeout: .milliseconds(150)) { _ in true }
        }
        await client.stop()
    }
}

@Suite struct RepeaterCLITests {
    @Test func cleansEchoAndPrefix() {
        #expect(RepeaterCLIClient.clean("get name\r\n  -> Hilltop\r\n", command: "get name") == "Hilltop")
        #expect(RepeaterCLIClient.clean("ver\r\n> v1.17.1 (build)\r\n", command: "ver") == "v1.17.1 (build)")
        #expect(RepeaterCLIClient.clean("neighbors\r\n  -> a:1:2\r\n  -> b:3:4", command: "neighbors") == "a:1:2\nb:3:4")
    }

    @Test func readAndWriteAgainstSimulator() async throws {
        let cli = RepeaterCLIClient(transport: SimulatedRepeaterTransport())
        await cli.start()
        let name = CLICatalog.setting("name")!
        #expect(try await cli.read(name) == .value("Demo Repeater"))
        _ = try await cli.write(name, value: "Changed")
        #expect(try await cli.read(name) == .value("Changed"))
        await cli.stop()
    }

    @Test func unknownKeyIsUnsupported() async throws {
        let cli = RepeaterCLIClient(transport: SimulatedRepeaterTransport())
        await cli.start()
        let bogus = CLISetting(id: "no.such.key", label: "", group: "", help: "", kind: .text)
        #expect(try await cli.read(bogus) == .unsupported)
        await cli.stop()
    }

    @Test func catalogHasNoDuplicatesAndBackupSkipsSecrets() {
        let ids = CLICatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!CLICatalog.backupable.contains { $0.sensitive })
        #expect(CLICatalog.all.allSatisfy { CLICatalog.groups.contains($0.group) })
    }
}

@Suite struct ReleaseParsingTests {
    private func asset(_ name: String) -> GitHubAsset {
        GitHubAsset(id: name.hashValue, name: name, size: 1, digest: nil, browserDownloadUrl: URL(string: "https://example.com/\(name)")!)
    }

    @Test func parsesESPMergedCompanion() throws {
        let a = FirmwareArtifact.parse(asset: asset("Heltec_v3_companion_radio_usb-v1.17.1-d929643-merged.bin"),
                                       role: .companion, releaseTag: "companion-v1.17.1")
        let art = try #require(a)
        #expect(art.board == "Heltec_v3")
        #expect(art.variant == "companion_radio_usb")
        #expect(art.version == "1.17.1")
        #expect(art.commit == "d929643")
        #expect(art.kind == .espFullImage)
        #expect(art.isESP32)
    }

    @Test func parsesESPAppImageAndUF2() throws {
        let app = try #require(FirmwareArtifact.parse(asset: asset("Heltec_v3_repeater-v1.17.1-d929643.bin"), role: .repeater, releaseTag: "repeater-v1.17.1"))
        #expect(app.kind == .espAppImage)
        #expect(app.variant == "repeater")

        let uf2 = try #require(FirmwareArtifact.parse(asset: asset("WioTrackerL1_repeater-v1.17.1-d929643.uf2"), role: .repeater, releaseTag: "repeater-v1.17.1"))
        #expect(uf2.kind == .uf2)
        #expect(uf2.board == "WioTrackerL1")

        let zip = try #require(FirmwareArtifact.parse(asset: asset("WioTrackerL1_repeater-v1.17.1-d929643.zip"), role: .repeater, releaseTag: "repeater-v1.17.1"))
        #expect(zip.kind == .nrfDFUPackage)
    }

    @Test func ignoresUnrelatedAssets() {
        #expect(FirmwareArtifact.parse(asset: asset("README.md"), role: .companion, releaseTag: "x") == nil)
    }

    @Test func buildsGroupByBoardAndVariant() throws {
        let release = GitHubRelease(tagName: "companion-v1.17.1", name: nil, prerelease: false, publishedAt: nil, assets: [
            asset("WioTrackerL1_companion_radio_ble-v1.17.1-d929643.uf2"),
            asset("WioTrackerL1_companion_radio_ble-v1.17.1-d929643.zip"),
            asset("WioTrackerL1_companion_radio_usb-v1.17.1-d929643.uf2"),
            asset("Heltec_v3_companion_radio_usb-v1.17.1-d929643.bin"),
            asset("Heltec_v3_companion_radio_usb-v1.17.1-d929643-merged.bin"),
        ])
        let builds = ReleaseClient.builds(from: release, role: .companion)
        #expect(builds.count == 3)
        let heltec = try #require(builds.first { $0.board == "Heltec_v3" })
        #expect(heltec.isESP32)
        #expect(heltec.fullImage?.kind == .espFullImage)
        let wioBLE = try #require(builds.first { $0.board == "WioTrackerL1" && $0.variant.hasSuffix("ble") })
        #expect(wioBLE.isUF2)
        #expect(wioBLE.artifacts.count == 2)
    }

    @Test func checksumVerification() {
        let data = Data("hello".utf8)
        // sha256("hello")
        let good = "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        #expect(ReleaseClient.verify(data, digest: good) == nil)
        #expect(ReleaseClient.verify(data, digest: "sha256:00") != nil)
        #expect(ReleaseClient.verify(data, digest: nil) == nil)
    }
}

@Suite struct UF2Tests {
    static func makeUF2(blocks: Int, family: UInt32 = 0xADA52840) -> Data {
        var out = Data()
        for i in 0..<blocks {
            var b: [UInt8] = []
            b.appendLE(UF2.magicStart0); b.appendLE(UF2.magicStart1); b.appendLE(UF2.familyFlag)
            b.appendLE(UInt32(0x26000 + i * 256)); b.appendLE(UInt32(256))
            b.appendLE(UInt32(i)); b.appendLE(UInt32(blocks)); b.appendLE(family)
            b += [UInt8](repeating: 0xAA, count: 476)
            b.appendLE(UF2.magicEnd)
            out.append(contentsOf: b)
        }
        return out
    }

    @Test func inspectsValidImage() throws {
        let info = try UF2.inspect(Self.makeUF2(blocks: 4))
        #expect(info.blockCount == 4)
        #expect(info.payloadBytes == 1024)
        #expect(info.familyName == "nRF52840")
        #expect(info.isNRF52)
        #expect(info.lowestAddress == 0x26000)
        #expect(info.highestAddress == 0x26000 + 4 * 256)
    }

    @Test func rejectsBadSizeAndMagic() {
        #expect(throws: UF2Error.self) { try UF2.inspect(Data(repeating: 0, count: 100)) }
        #expect(throws: UF2Error.self) { try UF2.inspect(Data(repeating: 0, count: 512)) }
        #expect(throws: UF2Error.self) { try UF2.inspect(Data()) }
    }

    @Test func recognizesOtherFamilies() throws {
        let info = try UF2.inspect(Self.makeUF2(blocks: 1, family: 0xE48BFF56))
        #expect(info.familyName == "RP2040")
        #expect(!info.isNRF52)
    }

    @Test func parsesInfoFile() {
        let text = "UF2 Bootloader 0.9.2 lib/nrfx\nModel: Seeed Wio Tracker L1\nBoard-ID: nRF52840-WioTrackerL1-v1\n"
        let v = UF2Volumes.parse(infoText: text, url: URL(fileURLWithPath: "/Volumes/WIOBOOT"))
        #expect(v.model == "Seeed Wio Tracker L1")
        #expect(v.boardID == "nRF52840-WioTrackerL1-v1")
        #expect(v.name == "WIOBOOT")
    }

    @Test func flashesToFakeVolume() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uf2test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let volume = UF2Volume(url: dir, model: "t", boardID: "t", bootloader: "t")
        let image = Self.makeUF2(blocks: 40)
        let outcome = try await UF2Flasher.flash(image: image, to: volume) { _ in }
        #expect(outcome == .volumeStillMounted)   // a plain directory never unmounts
        #expect(try Data(contentsOf: dir.appendingPathComponent("NEW.UF2")) == image)
    }
}

@Suite struct SnapshotTests {
    @Test func codableRoundTrip() throws {
        let s = ConfigSnapshot(kind: .repeater, deviceName: "R", board: "b", firmware: "1", values: ["name": "R", "tx": "20"])
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(ConfigSnapshot.self, from: e.encode(s))
        #expect(back.values == s.values)
        #expect(back.id == s.id)
    }
}

@Suite struct BlankValueTests {
    @Test func blankReplyIsAValueNotUnsupported() async throws {
        let cli = RepeaterCLIClient(transport: SimulatedRepeaterTransport())
        await cli.start()
        #expect(try await cli.read(CLICatalog.setting("guest.password")!) == .value(""))
        await cli.stop()
    }
}
