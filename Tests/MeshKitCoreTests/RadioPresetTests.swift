import Foundation
import Testing
@testable import MeshKitCore

private let realFeed = Data(#"""
{"config":{"suggested_radio_settings":{"info_message":"These presets are suggested by the community.","entries":[{"title":"Australia","description":"915.800MHz / SF10 / BW250 / CR5","frequency":"915.800","spreading_factor":"10","bandwidth":"250","coding_rate":"5"},{"title":"Australia (Narrow)","description":"916.575MHz / SF7 / BW62.5 / CR7","frequency":"916.575","spreading_factor":"7","bandwidth":"62.5","coding_rate":"7"},{"title":"Australia (Mid)","description":"915.075MHz / SF9 / BW125 / CR5","frequency":"915.075","spreading_factor":"9","bandwidth":"125","coding_rate":"5"},{"title":"Australia: SA, WA","description":"923.125MHz / SF8 / BW62.5 / CR8","frequency":"923.125","spreading_factor":"8","bandwidth":"62.5","coding_rate":"8"},{"title":"Australia: QLD","description":"923.125MHz / SF8 / BW62.5 / CR5","frequency":"923.125","spreading_factor":"8","bandwidth":"62.5","coding_rate":"5"},{"title":"Brazil","description":"923.125MHz / SF8 / BW62.5 / CR8","frequency":"923.125","spreading_factor":"8","bandwidth":"62.5","coding_rate":"8"},{"title":"Canada","description":"910.525MHz / SF7 / BW62.5 / CR5 / 3B","frequency":"910.525","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5","network_settings":{"path_hash_size":3}},{"title":"Costa Rica","description":"910.525MHz / SF11 / BW125 / CR5","frequency":"910.525","spreading_factor":"11","bandwidth":"125","coding_rate":"5"},{"title":"EU/UK (Narrow)","description":"869.618MHz / SF8 / BW62.5 / CR8","frequency":"869.618","spreading_factor":"8","bandwidth":"62.5","coding_rate":"8"},{"title":"EU/UK (Deprecated)","description":"869.525MHz / SF11 / BW250 / CR5","frequency":"869.525","spreading_factor":"11","bandwidth":"250","coding_rate":"5"},{"title":"Czech Republic (Narrow)","description":"869.432MHz / SF7 / BW62.5 / CR5 / 2B","frequency":"869.432","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5","network_settings":{"path_hash_size":2}},{"title":"EU 433MHz (Long Range)","description":"433.650MHz / SF11 / BW250 / CR5","frequency":"433.650","spreading_factor":"11","bandwidth":"250","coding_rate":"5"},{"title":"EU 433MHz (Narrow)","description":"433.650MHz / SF8 / BW62.5 / CR8","frequency":"433.650","spreading_factor":"8","bandwidth":"62.5","coding_rate":"8"},{"title":"Hungary","description":"869.618MHz / SF7 / BW62.5 / CR5 / 2B","frequency":"869.618","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5","network_settings":{"path_hash_size":2}},{"title":"Netherlands","description":"869.618MHz / SF7 / BW62.5 / CR5","frequency":"869.618","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5"},{"title":"Netherlands (Limburg)","description":"869.618MHz / SF8 / BW62.5 / CR8 / 2B","frequency":"869.618","spreading_factor":"8","bandwidth":"62.5","coding_rate":"8","network_settings":{"path_hash_size":2}},{"title":"New Zealand (Narrow)","description":"917.375MHz / SF7 / BW62.5 / CR5 / 2B","frequency":"917.375","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5","network_settings":{"path_hash_size":2}},{"title":"New Zealand (Gisborne)","description":"917.375MHz / SF11 / BW250 / CR5 / 1B","frequency":"917.375","spreading_factor":"11","bandwidth":"250","coding_rate":"5","network_settings":{"path_hash_size":1}},{"title":"Portugal 433","description":"433.375MHz / SF9 / BW62.5 / CR6","frequency":"433.375","spreading_factor":"9","bandwidth":"62.5","coding_rate":"6"},{"title":"Portugal 868","description":"869.618MHz / SF7 / BW62.5 / CR6","frequency":"869.618","spreading_factor":"7","bandwidth":"62.5","coding_rate":"6"},{"title":"Slovakia","description":"869.618MHz / SF7 / BW62.5 / CR5 / 2B","frequency":"869.618","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5","network_settings":{"path_hash_size":2}},{"title":"Switzerland","description":"869.618MHz / SF8 / BW62.5 / CR8","frequency":"869.618","spreading_factor":"8","bandwidth":"62.5","coding_rate":"8"},{"title":"USA","description":"910.525MHz / SF7 / BW62.5 / CR5","frequency":"910.525","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5"},{"title":"USA - Southern California","description":"927.875MHz / SF7 / BW62.5 / CR5 / 3B","frequency":"927.875","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5","network_settings":{"path_hash_size":3}},{"title":"Vietnam (Narrow)","description":"920.250MHz / SF8 / BW62.5 / CR5","frequency":"920.250","spreading_factor":"8","bandwidth":"62.5","coding_rate":"5"},{"title":"Vietnam (Deprecated)","description":"920.250MHz / SF11 / BW250 / CR5","frequency":"920.250","spreading_factor":"11","bandwidth":"250","coding_rate":"5"}]}}}
"""#.utf8)

private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("rp-\(UUID().uuidString)") }

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

@Suite struct RadioPresetTests {
    @Test func decodesTheRealFeed() throws {
        let presets = RadioPresetCatalog.decode(feed: realFeed)
        #expect(presets.count == 26)
        let usa = try #require(presets.first { $0.title == "USA" })
        #expect(usa.frequencyMHz == 910.525 && usa.bandwidthKHz == 62.5 && usa.spreadingFactor == 7 && usa.codingRate == 5)
        let canada = try #require(presets.first { $0.title == "Canada" })
        #expect(canada.pathHashSize == 3)
        let eu = try #require(presets.first { $0.title == "EU/UK (Narrow)" })
        #expect(eu.cliValue == "869.618,62.5,8,8")
        #expect(presets.allSatisfy { $0.isValid })
    }

    @Test func theBundledSnapshotMatchesTheRealFeed() {
        let live = RadioPresetCatalog.decode(feed: realFeed)
        #expect(RadioPresets.bundled.count == live.count)
        #expect(Set(RadioPresets.bundled.map(\.id)) == Set(live.map(\.id)))
        #expect(RadioPresets.bundled.allSatisfy { $0.isValid })
    }

    @Test func badEntriesAreDroppedBeforeTheyCanReachARadio() {
        let json = #"""
        {"config":{"suggested_radio_settings":{"entries":[
          {"title":"Good","frequency":"910.525","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5"},
          {"title":"Frequency too low","frequency":"5","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5"},
          {"title":"SF out of range","frequency":"910.525","spreading_factor":"99","bandwidth":"62.5","coding_rate":"5"},
          {"title":"CR out of range","frequency":"910.525","spreading_factor":"7","bandwidth":"62.5","coding_rate":"2"},
          {"title":"BW huge","frequency":"910.525","spreading_factor":"7","bandwidth":"9000","coding_rate":"5"},
          {"title":"Not a number","frequency":"abc","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5"},
          {"title":"","frequency":"910.525","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5"},
          {"title":"Bad hash","frequency":"910.525","spreading_factor":"7","bandwidth":"62.5","coding_rate":"5","network_settings":{"path_hash_size":9}},
          {"title":"Numbers as numbers","frequency":869.618,"spreading_factor":8,"bandwidth":62.5,"coding_rate":8}
        ]}}}
        """#
        #expect(RadioPresetCatalog.decode(feed: Data(json.utf8)).map(\.title) == ["Good", "Numbers as numbers"])
        #expect(RadioPresetCatalog.decode(feed: Data("not json".utf8)).isEmpty)
        #expect(RadioPresetCatalog.decode(feed: Data(#"{"config":{}}"#.utf8)).isEmpty)
    }

    @Test func matchWordingListsEveryPresetWithTheSameNumbers() throws {
        let presets = RadioPresets.bundled.filter {
            $0.matches(frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5)
        }
        #expect(presets.map(\.title) == ["Canada", "USA"])
        #expect(RadioPreset.matchSummary(presets) == "Matches the Canada and USA presets")
        #expect(RadioPreset.matchSummary([presets[1]]) == "Matches the USA preset")
        #expect(RadioPreset.matchSummary([]) == "Custom settings")
        let three = presets + [RadioPreset(title: "Mine", frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5)]
        #expect(RadioPreset.matchSummary(three) == "Matches Canada, USA and 1 other preset")
        #expect(RadioPreset.matchSummary(three + three) == "Matches Canada, USA and 4 other presets")
    }

    @Test func matchingFormattingAndGrouping() throws {
        let usa = RadioPreset(title: "USA", frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5)
        #expect(usa.matches(frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5))
        #expect(usa.matches(frequencyMHz: 910.5251, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5))   // float noise from the radio
        #expect(!usa.matches(frequencyMHz: 910.525, bandwidthKHz: 125, spreadingFactor: 7, codingRate: 5))
        #expect(!usa.matches(frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 8))
        #expect(usa.summary == "910.525 MHz · BW 62.5 kHz · SF7 · CR 4/5")
        #expect(RadioPreset(title: "x", frequencyMHz: 869.5, bandwidthKHz: 250, spreadingFactor: 11, codingRate: 5).cliValue == "869.5,250,11,5")
        let regions = Dictionary(grouping: RadioPresets.bundled, by: \.region)
        #expect(regions["Americas"]?.contains { $0.title == "Canada" } == true)
        #expect(regions["Europe"]?.contains { $0.title == "Switzerland" } == true)
        #expect(regions["Europe"]?.contains { $0.title.hasPrefix("EU 433") } == true)
        #expect(regions["Oceania"]?.contains { $0.title == "New Zealand (Narrow)" } == true)
        #expect(regions["Asia"]?.contains { $0.title.hasPrefix("Vietnam") } == true)
        #expect(regions["Other"] == nil)
    }
}

@Suite struct RadioPresetCatalogTests {
    @Test func fetchesCachesAndThenReusesTheCache() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Counter()
        let catalog = RadioPresetCatalog(cacheDirectory: dir) { _ in calls.hit(); return realFeed }

        let first = await catalog.load()
        #expect(first.presets.count == 26)
        if case .live = first.source {} else { Issue.record("expected live, got \(first.source)") }
        #expect(calls.count == 1)

        let second = await catalog.load()
        if case .cached = second.source {} else { Issue.record("expected cached, got \(second.source)") }
        #expect(calls.count == 1)

        _ = await catalog.load(forceRefresh: true)
        #expect(calls.count == 2)
    }

    @Test func aStaleCacheIsUsedWhenTheNetworkFails() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = await RadioPresetCatalog(cacheDirectory: dir) { _ in realFeed }.load()
        struct Offline: Error {}
        let offline = RadioPresetCatalog(cacheDirectory: dir) { _ in throw Offline() }
        let r = await offline.load(maxAge: 0)
        #expect(r.presets.count == 26)
        if case .cached = r.source {} else { Issue.record("expected cached, got \(r.source)") }
    }

    @Test func withNoCacheAndNoNetworkItFallsBackToTheBundledList() async {
        struct Offline: Error {}
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = await RadioPresetCatalog(cacheDirectory: dir) { _ in throw Offline() }.load()
        #expect(r.source == .bundled && r.presets == RadioPresets.bundled && !r.presets.isEmpty)
    }

    @Test func anUnusableFeedNeverReplacesAGoodList() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = await RadioPresetCatalog(cacheDirectory: dir) { _ in realFeed }.load()
        let broken = RadioPresetCatalog(cacheDirectory: dir) { _ in Data(#"{"config":{"suggested_radio_settings":{"entries":[]}}}"#.utf8) }
        let r = await broken.load(forceRefresh: true)
        #expect(r.presets.count == 26)
    }
}

@Suite struct UserRadioPresetTests {
    @Test func saveReplaceDeleteAndRejectInvalid() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = UserRadioPresetStore(directory: dir)
        #expect(store.list().isEmpty)

        let a = RadioPreset(title: "Home mesh", frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 5)
        #expect(try store.save(a).count == 1)
        let b = RadioPreset(title: "home MESH", frequencyMHz: 915, bandwidthKHz: 125, spreadingFactor: 9, codingRate: 6)
        let after = try store.save(b)
        #expect(after.count == 1 && after[0].frequencyMHz == 915)
        _ = try store.save(RadioPreset(title: "Another", frequencyMHz: 868, bandwidthKHz: 250, spreadingFactor: 11, codingRate: 5))
        #expect(store.list().map(\.title) == ["Another", "home MESH"])

        #expect(throws: RadioPresetError.self) { try store.save(RadioPreset(title: "Bad", frequencyMHz: 1, bandwidthKHz: 1, spreadingFactor: 1, codingRate: 1)) }
        #expect(try store.delete(after[0]).count == 1)
    }
}
