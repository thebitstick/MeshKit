import Foundation

public enum RadioPresetSource: Equatable, Sendable {
    case live(Date)
    case cached(Date)
    case bundled

    public var description: String {
        switch self {
        case .live(let d), .cached(let d): "MeshCore community list, \(d.formatted(date: .abbreviated, time: .omitted))"
        case .bundled: "Built-in list (couldn't reach the community list)"
        }
    }
}

/// The community-suggested radio settings that MeshCore's own apps show, with a local cache and an offline fallback.
///
/// The feed is public JSON (`api.meshcore.nz`); its entries are validated before use because they end up written to
/// radios, and anything out of range is dropped.
public struct RadioPresetCatalog: Sendable {
    public static let feedURL = URL(string: "https://api.meshcore.nz/api/v1/config")!

    private let cacheFile: URL
    private let feed: URL
    private let fetch: @Sendable (URL) async throws -> Data

    public init(
        cacheDirectory: URL = RadioPresetCatalog.defaultDirectory,
        feed: URL = RadioPresetCatalog.feedURL,
        fetch: @escaping @Sendable (URL) async throws -> Data = RadioPresetCatalog.networkFetch
    ) {
        cacheFile = cacheDirectory.appendingPathComponent("radio-presets-cache.json")
        self.feed = feed
        self.fetch = fetch
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeshKit", isDirectory: true)
    }

    @Sendable public static func networkFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("MeshKit", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ReleaseError.http(http.statusCode) }
        return data
    }

    private struct Cache: Codable { var fetchedAt: Date; var presets: [RadioPreset] }

    public func load(maxAge: TimeInterval = 24 * 3600, forceRefresh: Bool = false) async -> (presets: [RadioPreset], source: RadioPresetSource) {
        let cache = readCache()
        if !forceRefresh, let cache, Date().timeIntervalSince(cache.fetchedAt) < maxAge, !cache.presets.isEmpty {
            return (cache.presets, .cached(cache.fetchedAt))
        }
        if let data = try? await fetch(feed) {
            let presets = Self.decode(feed: data)
            if !presets.isEmpty {
                writeCache(Cache(fetchedAt: Date(), presets: presets))
                return (presets, .live(Date()))
            }
        }
        if let cache, !cache.presets.isEmpty { return (cache.presets, .cached(cache.fetchedAt)) }
        return (RadioPresets.bundled, .bundled)
    }

    private func readCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard var cache = try? decoder.decode(Cache.self, from: data) else { return nil }
        cache.presets = cache.presets.filter(\.isValid)     // the file is ours, but a bad edit shouldn't reach a radio
        return cache
    }

    private func writeCache(_ cache: Cache) {
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(cache).write(to: cacheFile)
    }

    // MARK: Decoding

    /// The feed gives numbers as strings ("910.525"); accept either.
    private struct LooseNumber: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { value = d } else if let s = try? c.decode(String.self) { value = Double(s) } else { value = nil }
        }
    }

    private struct Feed: Decodable {
        struct Config: Decodable {
            struct Settings: Decodable {
                struct Entry: Decodable {
                    struct Network: Decodable { let pathHashSize: Int? ; enum CodingKeys: String, CodingKey { case pathHashSize = "path_hash_size" } }
                    let title: String
                    let frequency: LooseNumber
                    let spreadingFactor: LooseNumber
                    let bandwidth: LooseNumber
                    let codingRate: LooseNumber
                    let networkSettings: Network?
                    enum CodingKeys: String, CodingKey {
                        case title, frequency, bandwidth
                        case spreadingFactor = "spreading_factor", codingRate = "coding_rate", networkSettings = "network_settings"
                    }
                }
                let entries: [Entry]
            }
            let suggestedRadioSettings: Settings
            enum CodingKeys: String, CodingKey { case suggestedRadioSettings = "suggested_radio_settings" }
        }
        let config: Config
    }

    public static func decode(feed data: Data) -> [RadioPreset] {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return [] }
        return feed.config.suggestedRadioSettings.entries.prefix(100).compactMap { e in
            guard let f = e.frequency.value, let bw = e.bandwidth.value, let sf = e.spreadingFactor.value, let cr = e.codingRate.value else { return nil }
            let p = RadioPreset(title: e.title.trimmingCharacters(in: .whitespaces), frequencyMHz: f, bandwidthKHz: bw,
                                spreadingFactor: Int(sf), codingRate: Int(cr), pathHashSize: e.networkSettings?.pathHashSize)
            return p.isValid ? p : nil
        }
    }
}

public struct UserRadioPresetStore: Sendable {
    private let file: URL

    public init(directory: URL = RadioPresetCatalog.defaultDirectory) {
        file = directory.appendingPathComponent("radio-presets-user.json")
    }

    public func list() -> [RadioPreset] {
        guard let data = try? Data(contentsOf: file), let all = try? JSONDecoder().decode([RadioPreset].self, from: data) else { return [] }
        return all.filter(\.isValid).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    public func save(_ preset: RadioPreset) throws -> [RadioPreset] {
        guard preset.isValid else { throw RadioPresetError.invalid }
        var all = list().filter { $0.title.caseInsensitiveCompare(preset.title) != .orderedSame }
        all.append(preset)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: file)
        return list()
    }

    @discardableResult
    public func delete(_ preset: RadioPreset) throws -> [RadioPreset] {
        let remaining = list().filter { $0.id != preset.id }
        try JSONEncoder().encode(remaining).write(to: file)
        return list()
    }
}

public enum RadioPresetError: Error, LocalizedError {
    case invalid
    public var errorDescription: String? { "That isn't a valid radio setting: check the frequency, bandwidth, spreading factor and coding rate." }
}
