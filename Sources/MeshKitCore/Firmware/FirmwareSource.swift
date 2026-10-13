import Foundation

/// A GitHub project the person added to get MeshCore builds from, in addition to the official releases.
public struct FirmwareSource: Codable, Hashable, Identifiable, Sendable {
    public var repository: String
    public var name: String

    public var id: String { repository }

    public init?(repository: String, name: String = "") {
        guard let repository = Self.normalize(repository) else { return nil }
        self.repository = repository
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        self.name = trimmed.isEmpty ? String(repository.split(separator: "/")[1]) : trimmed
    }

    /// Accepts `owner/repo` or a github.com URL for the project.
    public static func normalize(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.hasSuffix(".git") { value.removeLast(4) }
        while value.hasSuffix("/") { value.removeLast() }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count == 2 || ["releases", "tree", "blob"].contains(String(parts[2])) else { return nil }
        let valid = #/^[A-Za-z0-9][A-Za-z0-9._-]*$/#
        guard parts[0].wholeMatch(of: valid) != nil, parts[1].wholeMatch(of: valid) != nil else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}

public enum FirmwareSourceStore {
    static let key = "firmwareSources"

    public static func load(_ defaults: UserDefaults = .standard) -> [FirmwareSource] {
        guard let data = defaults.data(forKey: key), let sources = try? JSONDecoder().decode([FirmwareSource].self, from: data) else { return [] }
        return sources.filter { FirmwareSource.normalize($0.repository) == $0.repository }
    }

    public static func save(_ sources: [FirmwareSource], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(sources), forKey: key)
    }
}
