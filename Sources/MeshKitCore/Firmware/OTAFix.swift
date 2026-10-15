import Foundation

/// The OTAFIX build of the Adafruit nRF52 bootloader, which makes Bluetooth firmware updates (DFU) more reliable and
/// falls back to DFU mode when the application is broken. MeshCore's FAQ recommends it. Each supported board has its own
/// update file, installed by copying it to the board's UF2 bootloader drive.
public enum OTAFix {
    public static let repository = "oltaco/Adafruit_nRF52_Bootloader_OTAFIX"
    public static let updateFamily: UInt32 = 0xD663823C

    private static let meshCore: [String: String] = [
        "heltec_t114": "heltec_t114", "heltec_t114_without_display": "heltec_t114", "heltec_t096": "heltec_t096", "heltec_t1": "heltec_t1",
        "lilygo_t-echo": "lilygo_techo", "wiotrackerl1": "wio_tracker_l1", "wiotrackerl1eink": "wio_tracker_l1",
        "rak_4631": "wiscore_rak4631_board", "rak_4631_gps": "wiscore_rak4631_board", "rak_3401": "wiscore_rak3401",
        "rak_wismesh_tag": "wismesh_tag", "thinknode_m1": "thinknode_m1", "thinknode_m3": "thinknode_m3", "thinknode_m6": "thinknode_m6",
        "t1000e": "t1000_e", "sensecap_solar": "sensecap_solar_p1", "xiao_nrf52": "xiao_nrf52840_ble", "promicro": "promicro_nrf52840",
    ]

    private static let meshtastic: [String: String] = [
        "heltec-mesh-node-t114": "heltec_t114", "heltec-mesh-node-t096": "heltec_t096", "heltec-mesh-node-t1": "heltec_t1",
        "t-echo": "lilygo_techo", "t-echo-inkhud": "lilygo_techo", "seeed_wio_tracker_l1": "wio_tracker_l1",
        "seeed_wio_tracker_l1_eink": "wio_tracker_l1", "seeed_wio_tracker_l1_eink-inkhud": "wio_tracker_l1",
        "rak4631": "wiscore_rak4631_board", "rak3401-1watt": "wiscore_rak3401", "rak_wismeshtag": "wismesh_tag",
        "thinknode_m1": "thinknode_m1", "thinknode_m1-inkhud": "thinknode_m1", "thinknode_m3": "thinknode_m3", "thinknode_m6": "thinknode_m6",
        "tracker-t1000-e": "t1000_e", "seeed_solar_node": "sensecap_solar_p1", "seeed_xiao_nrf52840_kit": "xiao_nrf52840_ble",
        "nrf52_promicro_diy_tcxo": "promicro_nrf52840",
    ]

    /// "OTAFIX2.2-BP1.3" from a bootloader line such as `UF2 Bootloader 0.9.2-OTAFIX2.2-BP1.3 lib/nrfx …`, or nil for other bootloaders.
    public static func installedVersion(inBootloader text: String) -> String? {
        text.firstMatch(of: #/OTAFIX\d+(?:\.\d+)*(?:-BP\d+(?:\.\d+)*)?/#).map { String($0.0) }
    }

    public static func boardID(meshCoreSlug slug: String) -> String? { meshCore[slug.lowercased()] }
    public static func boardID(meshtasticSlug slug: String) -> String? { meshtastic[slug.lowercased()] }

    public struct Update: Sendable {
        public let tag: String
        public let asset: GitHubAsset
    }

    public enum OTAFixError: LocalizedError {
        case noUpdateFile(String)
        public var errorDescription: String? { "The latest OTAFIX release has no bootloader update for \(self.board)." }
        var board: String { if case .noUpdateFile(let b) = self { b } else { "" } }
    }

    public static var boardIDs: Set<String> { Set(meshCore.values).union(meshtastic.values) }

    public static func latestRelease() async throws -> GitHubRelease {
        let client = ReleaseClient()
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        let data = try await DiskCache.fetch("otafix-latest") {
            let (data, response) = try await URLSession.shared.data(for: client.request(url))
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ReleaseError.http(http.statusCode) }
            return data
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    public static func update(for boardID: String, in release: GitHubRelease) throws -> Update {
        guard let asset = release.assets.first(where: { $0.name.hasPrefix("update-\(boardID)_bootloader-") && $0.name.hasSuffix("_nosd.uf2") }) else {
            throw OTAFixError.noUpdateFile(boardID)
        }
        return Update(tag: release.tagName, asset: asset)
    }

    public static func latestUpdate(for boardID: String) async throws -> Update {
        try update(for: boardID, in: try await latestRelease())
    }

    /// Downloads into the cache (reusing a verified earlier download) and returns the file's location.
    public static func download(_ update: Update) async throws -> URL {
        let dir = ReleaseClient.cacheDirectory.appendingPathComponent("otafix").appendingPathComponent(ReleaseClient.safeComponent(update.tag))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(ReleaseClient.safeComponent(update.asset.name))
        if let existing = try? Data(contentsOf: dest), ReleaseClient.verify(existing, digest: update.asset.digest) == nil { return dest }
        let (tmp, response) = try await URLSession.shared.download(for: ReleaseClient().request(update.asset.browserDownloadUrl))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ReleaseError.http(http.statusCode) }
        let data = try Data(contentsOf: tmp)
        if let mismatch = ReleaseClient.verify(data, digest: update.asset.digest) { throw mismatch }
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        return dest
    }
}
