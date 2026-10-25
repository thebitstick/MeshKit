import Foundation

/// How long a node name each firmware keeps. They count UTF-8 bytes, not letters, so one accented letter uses two.
public enum NameLimits {
    /// Checked on a MeshCore companion: a longer name is cut at 31 bytes, even in the middle of a character.
    public static let meshCore = 31
    /// What other nodes see when the node shares its location in adverts. A MeshCore advert carries 32 bytes of data
    /// (`MAX_ADVERT_DATA_SIZE`): a flag byte, eight bytes of location when the node shares one, then the name, cut to
    /// what is left. Whether a location goes out depends on the node's advert location policy (none, prefs or share), not
    /// on the numbers: a node with a location set and sharing off still advertises 31 bytes of name, and one that shares
    /// advertises 23 even at 0, 0.
    public static let meshCoreAdvertised = 23
    /// Repeaters and room servers are held to 23: they will usually share their location, and nothing past it would be shown.
    public static let meshCoreRepeater = meshCoreAdvertised

    public static let meshtasticLong = 39
    public static let meshtasticShort = 4

    public static func meshCore(sharingLocation: Bool) -> Int { sharingLocation ? meshCoreAdvertised : meshCore }

    /// The longest start of `text` that fits in `bytes`, never cutting a character in half.
    public static func fit(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes { break }
            result.append(character); used += size
        }
        return result
    }

    public static func used(_ text: String) -> Int { text.utf8.count }

    /// Characters a repeater or room server refuses in its name (`set name` answers "Error, bad chars").
    public static let repeaterForbidden: Set<Character> = ["[", "]", "\\", ":", ",", "?", "*"]

    public static func repeaterForbiddenCharacters(in text: String) -> [Character] {
        var seen: [Character] = []
        for c in text where repeaterForbidden.contains(c) && !seen.contains(c) { seen.append(c) }
        return seen
    }

    /// The name with each forbidden character replaced by a space, then runs of spaces collapsed.
    public static func repeaterSafe(_ text: String) -> String {
        guard text.contains(where: { repeaterForbidden.contains($0) }) else { return text }
        let spaced = String(text.map { repeaterForbidden.contains($0) ? " " : $0 })
        return spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

extension NodeIdentity {
    /// The same node with a name a repeater or room server accepts: no forbidden characters, at most 23 bytes.
    public func fittedForRepeater() -> NodeIdentity {
        NodeIdentity(name: NameLimits.fit(NameLimits.repeaterSafe(name), bytes: NameLimits.meshCoreRepeater), latitude: latitude, longitude: longitude)
    }

    /// The same node with a name that fits the firmware it is going to.
    public func fitted(toBytes bytes: Int) -> NodeIdentity {
        NodeIdentity(name: NameLimits.fit(name, bytes: bytes), latitude: latitude, longitude: longitude)
    }

    public var nameFitsMeshCore: Bool { name.utf8.count <= NameLimits.meshCore }

    /// A name other nodes would cut short if the node were to share its location.
    public var exceedsLocationAdvertLimit: Bool { hasLocation && name.utf8.count > NameLimits.meshCoreAdvertised }
}
