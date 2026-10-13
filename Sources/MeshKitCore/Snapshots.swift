import Foundation

public struct ConfigSnapshot: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case companion, repeater, meshtastic }

    public var id = UUID()
    public var created = Date()
    public var kind: Kind
    public var deviceName: String
    public var board: String?
    public var firmware: String?
    public var values: [String: String]

    public init(kind: Kind, deviceName: String, board: String? = nil, firmware: String? = nil, values: [String: String]) {
        self.kind = kind; self.deviceName = deviceName; self.board = board; self.firmware = firmware; self.values = values
    }
}

public enum SnapshotStore {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MeshKit/Backups", isDirectory: true)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func save(_ snapshot: ConfigSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: directory.appendingPathComponent("\(snapshot.id.uuidString).json"))
    }

    public static func list() -> [ConfigSnapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ConfigSnapshot.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    public static func delete(_ snapshot: ConfigSnapshot) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(snapshot.id.uuidString).json"))
    }
}
