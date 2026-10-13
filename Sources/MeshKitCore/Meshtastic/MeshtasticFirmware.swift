import CryptoKit
import Foundation

/// Meshtastic publishes two kinds of release on GitHub. Their titles say "Alpha" or "Beta", but the channel that
/// matters is GitHub's own prerelease flag: releases that aren't marked prerelease are the ones Meshtastic
/// recommends (and what its web flasher lists as stable); prereleases are the alpha builds.
public enum MeshtasticChannel: String, CaseIterable, Identifiable, Sendable {
    case stable = "Stable", alpha = "Alpha"
    public var id: String { rawValue }

    public var blurb: String {
        switch self {
        case .stable: "The releases Meshtastic recommends for everyday use."
        case .alpha: "Pre-release builds with the newest changes. May have bugs."
        }
    }
}

public struct MeshtasticRelease: Identifiable, Hashable, Sendable {
    public let tag: String
    public let version: String
    public let channel: MeshtasticChannel
    public let publishedAt: Date?
    public let assets: [GitHubAsset]

    public var id: String { tag }

    public func asset(named name: String) -> GitHubAsset? { assets.first { $0.name == name } }

    public func platformZip(_ platform: String) -> GitHubAsset? { asset(named: "firmware-\(platform)-\(version).zip") }

    public var pageURL: URL {
        // The tag comes from a web API, so it's percent-encoded and the URL falls back to the releases page rather than
        // trapping on something unexpected.
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
        return encoded.flatMap { URL(string: "https://github.com/meshtastic/firmware/releases/tag/\($0)") }
            ?? URL(string: "https://github.com/meshtastic/firmware/releases")!
    }
}

public struct MeshtasticBoard: Identifiable, Hashable, Sendable {
    public let slug: String
    public let platform: String
    public var displayName: String
    public var supportLevel: Int?
    public var activelySupported: Bool
    public var requiresDFU: Bool
    public var vendor: String?

    public var id: String { slug }
    public var isESP32: Bool { platform.hasPrefix("esp32") }
    public var isNRF52: Bool { platform == "nrf52840" }
    public var isFlashable: Bool { isESP32 || isNRF52 }

    public var architectureLabel: String {
        switch platform {
        case "nrf52840": "nRF52840"
        case "esp32": "ESP32"
        case "esp32s3": "ESP32-S3"
        case "esp32c3": "ESP32-C3"
        case "esp32c6": "ESP32-C6"
        default: platform.uppercased()
        }
    }

    static func prettify(_ slug: String) -> String { prettyBoardName(slug) }
}

public struct MeshtasticBoardMetadata: Decodable, Sendable {
    public struct File: Decodable, Sendable { public let name: String; public let md5: String?; public let bytes: Int?; public let partName: String? }
    public struct Partition: Decodable, Sendable { public let name: String; public let subtype: String?; public let offset: String; public let size: String }

    public let version: String
    public let mcu: String
    public let files: [File]
    public let part: [Partition]?
    public let displayName: String?
    public let hwModel: Int?

    public func offset(ofPartition name: String) -> UInt32? { parse(part?.first { $0.name == name }?.offset) }
    public func offset(ofSubtype subtype: String) -> UInt32? { parse(part?.first { $0.subtype == subtype }?.offset) }

    private func parse(_ hex: String?) -> UInt32? {
        guard var h = hex?.lowercased() else { return nil }
        if h.hasPrefix("0x") { h.removeFirst(2) }
        return UInt32(h, radix: 16)
    }
}

public enum MeshtasticError: Error, LocalizedError {
    case http(Int)
    case missingAsset(String)
    case missingFile(String)
    case checksum(String)
    case unsupportedPlatform(String)

    public var errorDescription: String? {
        switch self {
        case .http(let c): "Meshtastic's servers answered HTTP \(c)"
        case .missingAsset(let n): "This release doesn't include \(n)"
        case .missingFile(let n): "The firmware package is missing \(n)"
        case .checksum(let n): "\(n) doesn't match the checksum published with the release"
        case .unsupportedPlatform(let p): "MeshKit can't flash \(p) boards yet"
        }
    }
}

public enum MeshtasticInstallMode: String, CaseIterable, Identifiable, Sendable {
    case update = "Update"
    case fresh = "Clean install"

    public var id: String { rawValue }
    public var blurb: String {
        switch self {
        case .update: "Replaces the firmware and keeps your settings, channels and keys."
        case .fresh: "Erases the whole flash first. Use for a new board or when something is broken. Settings are lost."
        }
    }
}

public struct MeshtasticCatalog: Sendable {
    public init() {}

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("MeshKit", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com", let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw MeshtasticError.http(http.statusCode) }
        return data
    }

    public func releases(limit: Int = 12) async throws -> [MeshtasticRelease] {
        let data = try await fetch(URL(string: "https://api.github.com/repos/meshtastic/firmware/releases?per_page=40")!)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let all = try decoder.decode([GitHubRelease].self, from: data)
        return Self.releases(from: all, limit: limit)
    }

    static func releases(from all: [GitHubRelease], limit: Int) -> [MeshtasticRelease] {
        all.compactMap { rel in
            let name = rel.name ?? rel.tagName
            guard !name.localizedCaseInsensitiveContains("revoked") else { return nil }
            let version = rel.tagName.hasPrefix("v") ? String(rel.tagName.dropFirst()) : rel.tagName
            guard rel.assets.contains(where: { $0.name == "firmware-\(version).json" }) else { return nil }
            let channel: MeshtasticChannel = rel.prerelease ? .alpha : .stable
            return MeshtasticRelease(tag: rel.tagName, version: version, channel: channel, publishedAt: rel.publishedAt, assets: rel.assets)
        }
        .prefix(limit).map { $0 }
    }

    private struct Manifest: Decodable { struct Target: Decodable { let board: String; let platform: String }; let targets: [Target] }
    private struct Hardware: Decodable {
        let platformioTarget: String
        let displayName: String?
        let supportLevel: Int?
        let activelySupported: Bool?
        let requiresDfu: Bool?
        let tags: [String]?
    }

    public func boards(in release: MeshtasticRelease) async throws -> [MeshtasticBoard] {
        guard let manifestAsset = release.asset(named: "firmware-\(release.version).json") else {
            throw MeshtasticError.missingAsset("firmware-\(release.version).json")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: try await fetch(manifestAsset.browserDownloadUrl))
        // The hardware list is a nicety; fall back to prettified slugs if it can't be reached.
        let hardware = (try? JSONDecoder().decode([Hardware].self, from: try await fetch(URL(string: "https://api.meshtastic.org/resource/deviceHardware")!))) ?? []
        return Self.merge(manifest.targets.map { ($0.board, $0.platform) }, hardware: hardware)
    }

    private static func merge(_ targets: [(String, String)], hardware: [Hardware]) -> [MeshtasticBoard] {
        let bySlug = Dictionary(hardware.map { ($0.platformioTarget, $0) }, uniquingKeysWith: { a, _ in a })
        return targets.map { slug, platform in
            let hw = bySlug[slug]
            return MeshtasticBoard(slug: slug, platform: platform, displayName: hw?.displayName ?? MeshtasticBoard.prettify(slug),
                                   supportLevel: hw?.supportLevel, activelySupported: hw?.activelySupported ?? true,
                                   requiresDFU: hw?.requiresDfu ?? false, vendor: hw?.tags?.first)
        }
        .sorted { ($0.supportLevel ?? 9, $0.displayName.lowercased()) < ($1.supportLevel ?? 9, $1.displayName.lowercased()) }
    }

    public func package(for board: MeshtasticBoard, in release: MeshtasticRelease) throws -> MeshtasticPackage {
        guard board.isFlashable else { throw MeshtasticError.unsupportedPlatform(board.architectureLabel) }
        guard let zip = release.platformZip(board.platform) else { throw MeshtasticError.missingAsset("firmware-\(board.platform)-\(release.version).zip") }
        return MeshtasticPackage(board: board, version: release.version, zip: RemoteZip(url: zip.browserDownloadUrl, size: zip.size))
    }
}

public struct MeshtasticPackage: Sendable {
    public let board: MeshtasticBoard
    public let version: String
    let zip: RemoteZip

    public init(board: MeshtasticBoard, version: String, zip: RemoteZip) {
        self.board = board; self.version = version; self.zip = zip
    }

    private func name(_ suffix: String, prefix: String = "firmware") -> String { "\(prefix)-\(board.slug)-\(version)\(suffix)" }

    private func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public func metadata() async throws -> MeshtasticBoardMetadata {
        let data = try await zip.read(name(".mt.json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase     // `part_name`
        return try decoder.decode(MeshtasticBoardMetadata.self, from: data)
    }

    private func verifiedFile(_ filename: String, metadata: MeshtasticBoardMetadata) async throws -> Data {
        let data = try await zip.read(filename)
        if let expected = metadata.files.first(where: { $0.name == filename })?.md5, md5(data) != expected {
            throw MeshtasticError.checksum(filename)
        }
        return data
    }

    /// ESP32 images for a flash.
    ///
    /// Update writes just the application at the app partition (0x10000 on every layout published so far).
    /// A clean install erases the chip and then writes, as Meshtastic's own `device-install` script does:
    /// the factory image at 0x0, the OTA loader at the second app partition, and the filesystem.
    public func espJob(mode: MeshtasticInstallMode) async throws -> ESPFlashJob {
        guard board.isESP32 else { throw MeshtasticError.unsupportedPlatform(board.architectureLabel) }
        let meta = try await metadata()
        switch mode {
        case .update:
            let file = name(".bin")
            let address = meta.offset(ofPartition: "app0") ?? 0x10000
            let data = try await verifiedFile(file, metadata: meta)
            return ESPFlashJob(images: [ESPFlashImage(name: file, address: address, data: [UInt8](data))], eraseAll: false)

        case .fresh:
            let factory = name(".factory.bin")
            var images = [ESPFlashImage(name: factory, address: 0, data: [UInt8](try await verifiedFile(factory, metadata: meta)))]

            let otaFile = "mt-\(meta.mcu)-ota.bin"
            if let otaAddress = meta.offset(ofSubtype: "ota_1") {
                images.append(ESPFlashImage(name: otaFile, address: otaAddress, data: [UInt8](try await verifiedFile(otaFile, metadata: meta))))
            }
            let fsFile = name(".bin", prefix: "littlefs")
            if let fsAddress = meta.offset(ofSubtype: "spiffs"), meta.files.contains(where: { $0.name == fsFile }) {
                images.append(ESPFlashImage(name: fsFile, address: fsAddress, data: [UInt8](try await verifiedFile(fsFile, metadata: meta)), isApplication: false))
            }
            return ESPFlashJob(images: images, eraseAll: true)
        }
    }

    public func uf2Image() async throws -> Data {
        guard board.isNRF52 else { throw MeshtasticError.unsupportedPlatform(board.architectureLabel) }
        let meta = try? await metadata()
        let file = name(".uf2")
        if let meta { return try await verifiedFile(file, metadata: meta) }
        return try await zip.read(file)
    }
}
