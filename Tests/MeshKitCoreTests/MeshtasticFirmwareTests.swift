import Foundation
import Testing
@testable import MeshKitCore

private let sampleZip = Data(base64Encoded: "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")!

@Suite struct RemoteZipTests {
    @Test func listsEntries() async throws {
        let zip = RemoteZip(source: DataRangeSource(sampleZip))
        let names = try await zip.entries().map(\.name)
        #expect(names == ["hello.txt", "bin/data.bin", "empty.txt", "firmware-demo-1.0.mt.json"])
    }

    @Test func readsDeflatedAndStoredEntries() async throws {
        let zip = RemoteZip(source: DataRangeSource(sampleZip))
        let hello = try await zip.read("hello.txt")
        #expect(String(decoding: hello, as: UTF8.self) == String(repeating: "hello meshkit\n", count: 500))
        #expect(try await zip.read("bin/data.bin").count == 3000)
        #expect(try await zip.read("empty.txt").isEmpty)
    }

    @Test func missingEntryAndGarbageAreErrors() async throws {
        let zip = RemoteZip(source: DataRangeSource(sampleZip))
        await #expect(throws: ZipError.self) { _ = try await zip.read("nope") }
        let bad = RemoteZip(source: DataRangeSource(Data(repeating: 7, count: 500)))
        await #expect(throws: ZipError.self) { _ = try await bad.entries() }
    }

    @Test func detectsCorruptedPayload() async throws {
        var bytes = sampleZip
        let marker = bytes.range(of: Data("bin/data.bin".utf8))!.upperBound
        bytes[marker + 100] ^= 0xFF
        let zip = RemoteZip(source: DataRangeSource(bytes))
        await #expect(throws: ZipError.self) { _ = try await zip.read("bin/data.bin") }
    }

    @Test func readsOnlyTheBytesItNeeds() async throws {
        final class Counting: RangeSource, @unchecked Sendable {
            let inner: Data
            private let lock = NSLock()
            private(set) var bytesRead = 0
            var size: Int { inner.count }
            init(_ d: Data) { inner = d }
            func read(_ range: ClosedRange<Int>) async throws -> Data {
                lock.withLock { bytesRead += range.count }
                return inner.subdata(in: range.lowerBound..<range.upperBound + 1)
            }
        }
        let src = Counting(sampleZip)
        let zip = RemoteZip(source: src)
        _ = try await zip.read("hello.txt")
        #expect(src.bytesRead <= sampleZip.count * 2)
    }

    @Test func crcAndInflateHelpers() throws {
        #expect(ZLib.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        let data = [UInt8](repeating: 9, count: 5000)
        let z = try #require(ZLib.compress(data))
        #expect(ZLib.inflateRaw(Array(z[2..<z.count - 4]), expectedSize: data.count) == data)
    }
}

@Suite struct MeshtasticCatalogTests {
    private func release(_ tag: String, _ name: String, prerelease: Bool = false, assets: [String]) -> GitHubRelease {
        GitHubRelease(tagName: tag, name: name, prerelease: prerelease, publishedAt: nil, assets: assets.enumerated().map {
            GitHubAsset(id: $0.offset, name: $0.element, size: 1, digest: nil, browserDownloadUrl: URL(string: "https://example.com/\($0.element)")!)
        })
    }

    @Test func channelComesFromThePrereleaseFlagNotTheTitle() {
        let all = [
            release("v2.8.1.aaaaaaa", "Meshtastic Firmware 2.8.1.aaaaaaa Alpha", prerelease: true, assets: ["firmware-2.8.1.aaaaaaa.json"]),
            release("v2.8.0.bbbbbbb", "Meshtastic Firmware 2.8.0.bbbbbbb Alpha (Revoked)", prerelease: true, assets: ["firmware-2.8.0.bbbbbbb.json"]),
            release("v2.8.0.ccccccc", "Meshtastic Firmware 2.8.0.ccccccc", prerelease: true, assets: []),
            // Meshtastic titles its recommended releases "Beta"; they are not GitHub prereleases, so they are Stable.
            release("v2.7.26.ddddddd", "Meshtastic Firmware 2.7.26.ddddddd Beta", prerelease: false, assets: ["firmware-2.7.26.ddddddd.json"]),
            release("v2.6.0.eeeeeee", "Meshtastic Firmware 2.6.0.eeeeeee Technical Preview", prerelease: true, assets: ["firmware-2.6.0.eeeeeee.json"]),
        ]
        let r = MeshtasticCatalog.releases(from: all, limit: 10)
        #expect(r.map(\.version) == ["2.8.1.aaaaaaa", "2.7.26.ddddddd", "2.6.0.eeeeeee"])
        #expect(r.map(\.channel) == [.alpha, .stable, .alpha])
    }

    @Test func platformZipNameFollowsTheReleaseNamingScheme() {
        let all = [release("v2.7.26.ddddddd", "x Beta", assets: ["firmware-2.7.26.ddddddd.json", "firmware-esp32s3-2.7.26.ddddddd.zip"])]
        let r = MeshtasticCatalog.releases(from: all, limit: 5)[0]
        #expect(r.platformZip("esp32s3")?.name == "firmware-esp32s3-2.7.26.ddddddd.zip")
        #expect(r.platformZip("nrf52840") == nil)
    }

    @Test func metadataOffsetsParse() throws {
        let json = """
        {"version":"1","mcu":"esp32s3","files":[{"name":"a.bin","md5":"x","bytes":1,"part_name":"app0"}],
         "part":[{"name":"app0","subtype":"ota_0","offset":"0x10000","size":"0x330000"},
                 {"name":"app1","subtype":"ota_1","offset":"0x340000","size":"0x330000"},
                 {"name":"spiffs","subtype":"spiffs","offset":"0x670000","size":"0x180000"}]}
        """
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let m = try d.decode(MeshtasticBoardMetadata.self, from: Data(json.utf8))
        #expect(m.offset(ofPartition: "app0") == 0x10000)
        #expect(m.offset(ofSubtype: "ota_1") == 0x340000)
        #expect(m.offset(ofSubtype: "spiffs") == 0x670000)
        #expect(m.offset(ofSubtype: "nope") == nil)
        #expect(m.files[0].partName == "app0")
    }

    @Test func releasePageURLSurvivesUnusualTags() {
        func page(_ tag: String) -> String {
            MeshtasticRelease(tag: tag, version: "x", channel: .stable, publishedAt: nil, assets: []).pageURL.absoluteString
        }
        #expect(page("v2.7.26.54e0d8d") == "https://github.com/meshtastic/firmware/releases/tag/v2.7.26.54e0d8d")
        #expect(page("weird tag/with#odd%chars").hasPrefix("https://github.com/meshtastic/firmware/releases"))
        #expect(!page("a b").contains(" "))
    }

    @Test func flashablePlatformsAreESP32AndNRF52() {
        func board(_ p: String) -> MeshtasticBoard { MeshtasticBoard(slug: "x", platform: p, displayName: "x", supportLevel: 1, activelySupported: true, requiresDFU: false, vendor: nil) }
        #expect(board("esp32s3").isFlashable && board("esp32").isFlashable && board("nrf52840").isFlashable)
        #expect(!board("rp2040").isFlashable && !board("stm32").isFlashable)
    }
}

@Suite struct BoardNameTests {
    @Test(arguments: [
        ("Heltec_v3", "Heltec V3"), ("heltec-v3", "Heltec V3"), ("Heltec_mesh_solar", "Heltec Mesh Solar"),
        ("WioTrackerL1", "Wio Tracker L1"), ("WioTrackerL1Eink", "Wio Tracker L1 Eink"), ("RAK_3x72", "RAK 3x72"),
        ("seeed_wio_tracker_L1", "Seeed Wio Tracker L1"), ("Ebyte_EoRa-S3", "Ebyte EoRa S3"), ("T_Beam_S3_Supreme_SX1262", "T-Beam S3 Supreme SX1262"), ("GAT562_30S_Mesh_Kit", "GAT562 30S Mesh Kit"),
    ])
    func prettifiesSlugs(slug: String, expected: String) {
        #expect(prettyBoardName(slug) == expected)
    }

    @Test(arguments: [
        ("WioTrackerL1", "Seeed Wio Tracker L1", "Seeed Studio"), ("Xiao_C3", "Seeed Xiao C3", "Seeed Studio"),
        ("Heltec_v3", "Heltec V3", "Heltec"), ("heltec_v4_tft", "Heltec V4 Tft", "Heltec"),
        ("RAK_4631", "RAK 4631", "RAK Wireless"), ("LilyGo_TDeck", "LilyGo T-Deck", "LilyGo"),
        ("Tbeam_SX1262", "LilyGo T-Beam SX1262", "LilyGo"), ("ThinkNode_M1", "Elecrow ThinkNode M1", "Elecrow"),
        ("Station_G2", "B&Q Station G2", "B&Q Consulting"),
    ])
    func namesAreDescriptiveAndCarryTheMaker(slug: String, name: String, maker: String) {
        let asset = GitHubAsset(id: 1, name: "x", size: 1, digest: nil, browserDownloadUrl: URL(string: "https://example.com/x")!)
        let artifact = FirmwareArtifact(asset: asset, role: .companion, releaseTag: "t", board: slug, variant: "", version: "1", commit: "abc", kind: .uf2)
        #expect(artifact.boardDisplayName == name)
        #expect(BoardMaker.forSlug(slug)?.name == maker)
    }

    @Test func unknownMakersStayUnlabelled() {
        #expect(BoardMaker.forSlug("GAT562_30S_Mesh_Kit") == nil && BoardMaker.forSlug("Faketec") == nil)
    }
}

import Combine
import Observation

@Observable final class ObservedThing { var value = 0; var other = 0 }

@Suite @MainActor struct ObservationBridgeTests {
    @Test func firesOnEveryChangeToATrackedProperty() async throws {
        let thing = ObservedThing()
        let bridge = ObservationBridge { _ = thing.value }
        var fired = 0
        let sub = bridge.objectWillChange.sink { fired += 1 }
        defer { sub.cancel() }

        thing.value = 1
        try await Task.sleep(for: .milliseconds(50))
        #expect(fired == 1)
        thing.value = 2
        try await Task.sleep(for: .milliseconds(50))
        #expect(fired == 2)
        thing.other = 5
        try await Task.sleep(for: .milliseconds(50))
        #expect(fired == 2)
    }
}
