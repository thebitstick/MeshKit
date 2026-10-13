import CryptoKit
import Foundation

public struct BoardMaker: Sendable, Equatable {
    public let name: String
    let brand: String
    let prefixes: [String]

    static let all: [BoardMaker] = [
        BoardMaker(name: "Heltec", brand: "Heltec", prefixes: ["heltec"]),
        BoardMaker(name: "LilyGo", brand: "LilyGo", prefixes: ["lilygo", "tbeam", "t_beam", "tlora", "t_impulse", "techo"]),
        BoardMaker(name: "Seeed Studio", brand: "Seeed", prefixes: ["wio", "xiao", "sensecap", "meshtracker", "t1000"]),
        BoardMaker(name: "RAK Wireless", brand: "RAK", prefixes: ["rak"]),
        BoardMaker(name: "Elecrow", brand: "Elecrow", prefixes: ["thinknode"]),
        BoardMaker(name: "B&Q Consulting", brand: "B&Q", prefixes: ["station_g", "nano_g2"]),
        BoardMaker(name: "M5Stack", brand: "M5Stack", prefixes: ["m5stack"]),
        BoardMaker(name: "EByte", brand: "EByte", prefixes: ["ebyte"]),
        BoardMaker(name: "Waveshare", brand: "Waveshare", prefixes: ["waveshare"]),
        BoardMaker(name: "Meshnology", brand: "Meshnology", prefixes: ["meshnology"]),
        BoardMaker(name: "Keepteen", brand: "Keepteen", prefixes: ["keepteen"]),
        BoardMaker(name: "Ikoka", brand: "Ikoka", prefixes: ["ikoka"]),
        BoardMaker(name: "Raspberry Pi", brand: "Raspberry Pi", prefixes: ["picow"]),
    ]

    public static func forSlug(_ slug: String) -> BoardMaker? {
        let key = slug.lowercased()
        return all.first { m in m.prefixes.contains { key.hasPrefix($0) } }
    }
}

public func prettyBoardName(_ slug: String) -> String {
    // Brand names that are camel-cased on purpose must not be split.
    let protected = ["EoRa", "LoRa", "ThinkNode", "LilyGo", "WisMesh", "SenseCap"]
    var separated = slug.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    for (i, brand) in protected.enumerated() { separated = separated.replacingOccurrences(of: brand, with: "\u{1}\(i)\u{1}") }
    var spaced = ""
    var previous: Character?
    let chars = Array(separated)
    for (i, ch) in chars.enumerated() {
        if let p = previous, ch.isUppercase {
            let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
            // "TrackerL1" and "tracker" -> "Tracker L1"; "L1Eink" -> "L1 Eink"; but "30S" stays together.
            if p.isLowercase || (p.isNumber && nextIsLower) { spaced.append(" ") }
        }
        spaced.append(ch)
        previous = ch
    }
    for (i, brand) in protected.enumerated() { spaced = spaced.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: brand) }
    let words = spaced.split(separator: " ").map { word -> String in
        let w = String(word)
        return w == w.lowercased() ? w.prefix(1).uppercased() + w.dropFirst() : w
    }.joined(separator: " ")
    return words.replacingOccurrences(of: #"\bT (Echo|Deck|Beam|Lora|Impulse|Eth)\b"#, with: "T-$1", options: .regularExpression)
        .replacingOccurrences(of: #"\bT(Deck|Echo|Beam|Impulse|Eth)\b"#, with: "T-$1", options: .regularExpression)
        .replacingOccurrences(of: "Tbeam", with: "T-Beam").replacingOccurrences(of: "Tlora", with: "T-LoRa")
        .replacingOccurrences(of: "T-Lora", with: "T-LoRa")
}

public enum MeshCoreRole: String, CaseIterable, Identifiable, Sendable {
    case companion, repeater, roomServer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .companion: "Companion"
        case .repeater: "Repeater"
        case .roomServer: "Room server"
        }
    }

    var tagPrefix: String {
        switch self {
        case .companion: "companion-v"
        case .repeater: "repeater-v"
        case .roomServer: "room-server-v"
        }
    }

    var assetMarker: String {
        switch self {
        case .companion: "_companion_radio"
        case .repeater: "_repeater"
        case .roomServer: "_room_server"
        }
    }
}

public struct GitHubAsset: Decodable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let size: Int
    public let digest: String?
    public let browserDownloadUrl: URL
}

public struct GitHubRelease: Decodable, Hashable, Sendable {
    public let tagName: String
    public let name: String?
    public let prerelease: Bool
    public let publishedAt: Date?
    public let assets: [GitHubAsset]
}

public struct FirmwareArtifact: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case espFullImage = "ESP32 full image"
        case espAppImage = "ESP32 app image"
        case uf2 = "UF2"
        case nrfDFUPackage = "nRF DFU package"
        case other = "Other"
    }

    public let asset: GitHubAsset
    public let role: MeshCoreRole
    public let releaseTag: String
    public let board: String
    public let variant: String
    public let version: String
    public let commit: String
    public let kind: Kind

    public var id: Int { asset.id }
    public var boardDisplayName: String {
        let name = prettyBoardName(board)
        guard let maker = BoardMaker.forSlug(board), !name.lowercased().hasPrefix(maker.brand.lowercased()) else { return name }
        return "\(maker.brand) \(name)"
    }
    public var variantDisplayName: String {
        guard !variant.isEmpty else { return role.title }
        let acronyms = ["ble": "BLE", "usb": "USB", "wifi": "Wi-Fi", "tcp": "TCP", "kiss": "KISS"]
        let words = variant.split(separator: "_").map { acronyms[String($0)] ?? String($0) }
        return ([words[0].capitalized] + words.dropFirst()).joined(separator: " ")
    }
    public var isESP32: Bool { kind == .espFullImage || kind == .espAppImage }
    public var isFlashableFullImage: Bool { kind == .espFullImage || kind == .uf2 }

    public static func parse(asset: GitHubAsset, role: MeshCoreRole, releaseTag: String, requireRole: Bool = false) -> FirmwareArtifact? {
        let pattern = #/^(.+)-v(\d+(?:\.\d+)*(?:-[A-Za-z]+)*)-([0-9a-f]{6,})(-merged)?\.(bin|uf2|zip)$/#
        guard let m = asset.name.wholeMatch(of: pattern) else { return nil }
        var prefix = String(m.1)
        var version = String(m.2)
        // Some forks name the file for their own version and the MeshCore version they are based on:
        // `<board>_<role>_<conn>_<fork>_mm-v1.6.1_mc-v1.17.1-<hash>`. Their own version is the one that matters here.
        if let fork = prefix.wholeMatch(of: #/(.+)_[a-z]+-v(\d+(?:\.\d+)*)_[a-z]+/#) {
            prefix = String(fork.1); version = String(fork.2)
        }
        let board: String, variant: String
        if let r = prefix.range(of: role.assetMarker, options: .backwards) {
            board = String(prefix[..<r.lowerBound])
            variant = String(prefix[r.lowerBound...].dropFirst())
        } else {
            if requireRole { return nil }
            board = prefix; variant = ""
        }
        let kind: Kind = switch (String(m.5), m.4 != nil) {
        case ("bin", true): .espFullImage
        case ("bin", false): .espAppImage
        case ("uf2", _): .uf2
        case ("zip", _): .nrfDFUPackage
        default: .other
        }
        return FirmwareArtifact(asset: asset, role: role, releaseTag: releaseTag, board: board, variant: variant,
                                version: version, commit: String(m.3), kind: kind)
    }
}

public struct FirmwareBuild: Identifiable, Hashable, Sendable {
    public let board: String
    public let variant: String
    public let role: MeshCoreRole
    public let version: String
    public let artifacts: [FirmwareArtifact]

    public var id: String { "\(role.rawValue)/\(board)/\(variant)/\(version)" }
    public var title: String { artifacts[0].boardDisplayName }
    public var isESP32: Bool { artifacts.contains { $0.isESP32 } }
    public var isUF2: Bool { artifacts.contains { $0.kind == .uf2 } }
    public var fullImage: FirmwareArtifact? { artifacts.first { $0.kind == .espFullImage } ?? artifacts.first { $0.kind == .uf2 } }
}

public enum MeshCoreConnection: String, CaseIterable, Identifiable, Sendable {
    case usb, ble, wifi

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .usb: "USB"
        case .ble: "Bluetooth"
        case .wifi: "Wi-Fi"
        }
    }

    public var shortTitle: String {
        switch self {
        case .usb: "USB"
        case .ble: "BLE"
        case .wifi: "Wi-Fi"
        }
    }

    public var symbol: String {
        switch self {
        case .usb: "cable.connector"
        case .ble: "dot.radiowaves.left.and.right"
        case .wifi: "wifi"
        }
    }

    public var blurb: String {
        switch self {
        case .usb: "Serial companion. For computers and web apps over a cable, and what MeshKit configures. Choose this to manage the node from this Mac."
        case .ble: "Bluetooth companion. For pairing with the MeshCore phone apps. MeshKit can install it but can't configure it over Bluetooth yet."
        case .wifi: "Wi-Fi companion. Connects to apps over your network."
        }
    }

    public static func parse(variant: String) -> MeshCoreConnection? {
        guard variant.hasPrefix("companion_radio_") else { return nil }
        let rest = variant.dropFirst("companion_radio_".count)
        if let first = rest.split(separator: "_").first, let c = allCases.first(where: { $0.rawValue == first }) { return c }
        return allCases.first { variant.hasSuffix("_" + $0.rawValue) }
    }
}

extension FirmwareBuild {
    public var connection: MeshCoreConnection? { MeshCoreConnection.parse(variant: variant) }
}

public struct FirmwareBoardGroup: Identifiable, Hashable, Sendable {
    public let board: String
    public let title: String
    public let builds: [FirmwareBuild]

    public var id: String { board }
    public var connections: [MeshCoreConnection] {
        MeshCoreConnection.allCases.filter { c in builds.contains { $0.connection == c } }
    }
    public var maker: String? { BoardMaker.forSlug(board)?.name }
    public var isESP32: Bool { builds.contains { $0.isESP32 } }
    public var isUF2: Bool { builds.contains { $0.isUF2 } }

    public func build(for connection: MeshCoreConnection?) -> FirmwareBuild? {
        guard let connection else { return builds.first }
        return builds.first { $0.connection == connection }
    }

    public static func groups(from builds: [FirmwareBuild]) -> [FirmwareBoardGroup] {
        Dictionary(grouping: builds, by: \.board).map { board, bs in
            FirmwareBoardGroup(board: board, title: bs[0].title,
                               builds: bs.sorted { ($0.connection?.rawValue ?? "") < ($1.connection?.rawValue ?? "") })
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

public enum ReleaseError: Error, LocalizedError {
    case http(Int)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .http(let c): "GitHub answered with HTTP \(c)" + (c == 403 ? " (rate limited; set GITHUB_TOKEN)" : "")
        case .checksumMismatch(let e, let a): "Checksum mismatch: expected \(e.prefix(12))…, got \(a.prefix(12))…"
        }
    }
}

public struct ReleaseClient: Sendable {
    public static let officialRepository = "meshcore-dev/MeshCore"

    public var repository = ReleaseClient.officialRepository
    public var isOfficial: Bool { repository == Self.officialRepository }

    public init() {}

    public init(repository: String) { self.repository = repository }

    func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("MeshKit", forHTTPHeaderField: "User-Agent")
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    public func releases(for role: MeshCoreRole, limit: Int = 4) async throws -> [GitHubRelease] {
        // Roles share one release feed, so over-fetch and filter by tag prefix.
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=60")!
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ReleaseError.http(http.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let all = try decoder.decode([GitHubRelease].self, from: data)
        if isOfficial { return Array(all.filter { $0.tagName.hasPrefix(role.tagPrefix) }.prefix(limit)) }
        // Other projects don't split roles across tags, so a release counts if any of its files is a build for this role.
        return Array(all.filter { !Self.builds(from: $0, role: role).isEmpty }.prefix(limit))
    }

    /// `source` keeps same-named tags from different projects apart in the download cache.
    public static func builds(from release: GitHubRelease, role: MeshCoreRole, source: String? = nil) -> [FirmwareBuild] {
        let tag = source.map { "\($0)-\(release.tagName)" } ?? release.tagName
        let artifacts = release.assets.compactMap { FirmwareArtifact.parse(asset: $0, role: role, releaseTag: tag, requireRole: source != nil) }
        let grouped = Dictionary(grouping: artifacts) { "\($0.board)|\($0.variant)" }
        return grouped.values.map { group in
            let sorted = group.sorted { $0.kind.rawValue < $1.kind.rawValue }
            return FirmwareBuild(board: sorted[0].board, variant: sorted[0].variant, role: role,
                                 version: sorted[0].version, artifacts: sorted)
        }
        .sorted { ($0.title, $0.variant) < ($1.title, $1.variant) }
    }

    public static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MeshKit/firmware")
    }

    public func download(_ artifact: FirmwareArtifact) async throws -> URL {
        // Tag and file names come from a web API, so they are used as single path components only, never as paths.
        let dir = Self.cacheDirectory.appendingPathComponent(Self.safeComponent(artifact.releaseTag))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(Self.safeComponent(artifact.asset.name))

        if let existing = try? Data(contentsOf: dest), Self.verify(existing, digest: artifact.asset.digest) == nil { return dest }

        let (tmp, response) = try await URLSession.shared.download(for: request(artifact.asset.browserDownloadUrl))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ReleaseError.http(http.statusCode) }
        let data = try Data(contentsOf: tmp)
        if let mismatch = Self.verify(data, digest: artifact.asset.digest) { throw mismatch }
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        return dest
    }

    static func safeComponent(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_").replacingOccurrences(of: ":", with: "_")
        let trimmed = String(cleaned.drop { $0 == "." || $0 == " " })
        return trimmed.isEmpty ? "_" : String(trimmed.prefix(200))
    }

    static func verify(_ data: Data, digest: String?) -> ReleaseError? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let expected = String(digest.dropFirst(7))
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expected ? nil : .checksumMismatch(expected: expected, actual: actual)
    }
}
