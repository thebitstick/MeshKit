import Foundation

public struct RadioPreset: Identifiable, Codable, Hashable, Sendable {
    public var title: String
    public var frequencyMHz: Double
    public var bandwidthKHz: Double
    public var spreadingFactor: Int
    public var codingRate: Int
    /// Bytes per hop in routing paths (1 to 3) that the preset's community also uses, where it says so. Applied to
    /// repeaters through their `path.hash.mode` setting, which MeshKit leaves for you to change.
    public var pathHashSize: Int?

    public init(title: String, frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: Int, codingRate: Int, pathHashSize: Int? = nil) {
        self.title = title; self.frequencyMHz = frequencyMHz; self.bandwidthKHz = bandwidthKHz
        self.spreadingFactor = spreadingFactor; self.codingRate = codingRate; self.pathHashSize = pathHashSize
    }

    public var id: String { "\(title)|\(cliValue)" }

    public var cliValue: String { "\(Self.format(frequencyMHz)),\(Self.format(bandwidthKHz)),\(spreadingFactor),\(codingRate)" }

    public var summary: String {
        "\(Self.format(frequencyMHz)) MHz · BW \(Self.format(bandwidthKHz)) kHz · SF\(spreadingFactor) · CR 4/\(codingRate)"
    }

    public func matches(frequencyMHz f: Double, bandwidthKHz bw: Double, spreadingFactor sf: Int, codingRate cr: Int) -> Bool {
        abs(frequencyMHz - f) < 0.0006 && abs(bandwidthKHz - bw) < 0.001 && spreadingFactor == sf && codingRate == cr
    }

    /// Whether the numbers are inside what MeshCore firmware accepts. Presets from the network are checked with this
    /// before they are ever shown, since they end up written to a radio.
    public var isValid: Bool {
        (300...2500).contains(frequencyMHz) && (7.8...500).contains(bandwidthKHz)
            && (5...12).contains(spreadingFactor) && (5...8).contains(codingRate)
            && !title.isEmpty && title.count <= 60 && (pathHashSize.map { (1...3).contains($0) } ?? true)
    }

    static func format(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    public var region: String {
        let t = title.lowercased()
        if ["australia", "new zealand"].contains(where: t.hasPrefix) { return "Oceania" }
        if ["usa", "canada", "costa rica", "brazil"].contains(where: t.hasPrefix) { return "Americas" }
        if ["vietnam"].contains(where: t.hasPrefix) { return "Asia" }
        if t.hasPrefix("eu") || ["czech", "hungary", "netherlands", "portugal", "slovakia", "switzerland"].contains(where: t.hasPrefix) { return "Europe" }
        return "Other"
    }

    public static let regionOrder = ["Americas", "Europe", "Oceania", "Asia", "Other"]

    public static func matchSummary(_ matches: [RadioPreset]) -> String {
        let names = matches.map(\.title)
        switch names.count {
        case 0: return "Custom settings"
        case 1: return "Matches the \(names[0]) preset"
        case 2: return "Matches the \(names[0]) and \(names[1]) presets"
        default: return "Matches \(names[0]), \(names[1]) and \(names.count - 2) other preset\(names.count == 3 ? "" : "s")"
        }
    }
}

public enum RadioPresets {
    public static let bundled: [RadioPreset] = [
        RadioPreset(title: "Australia", frequencyMHz: 915.8, bandwidthKHz: 250, spreadingFactor: 10, codingRate: 5, pathHashSize: nil),
        RadioPreset(title: "Australia (Narrow)", frequencyMHz: 916.575, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 7, pathHashSize: nil),
        RadioPreset(title: "Australia (Mid)", frequencyMHz: 915.075, bandwidthKHz: 125, spreadingFactor: 9, codingRate: 5, pathHashSize: nil),
        RadioPreset(title: "Australia: SA, WA", frequencyMHz: 923.125, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8, pathHashSize: nil),
        RadioPreset(title: "Australia: QLD", frequencyMHz: 923.125, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 5, pathHashSize: nil),
        RadioPreset(title: "Brazil", frequencyMHz: 923.125, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8, pathHashSize: nil),
        RadioPreset(title: "Canada", frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: 3),
        RadioPreset(title: "Costa Rica", frequencyMHz: 910.525, bandwidthKHz: 125, spreadingFactor: 11, codingRate: 5, pathHashSize: nil),
        RadioPreset(title: "EU/UK (Narrow)", frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8, pathHashSize: nil),
        RadioPreset(title: "EU/UK (Deprecated)", frequencyMHz: 869.525, bandwidthKHz: 250, spreadingFactor: 11, codingRate: 5, pathHashSize: nil),
        RadioPreset(title: "Czech Republic (Narrow)", frequencyMHz: 869.432, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: 2),
        RadioPreset(title: "EU 433MHz (Long Range)", frequencyMHz: 433.65, bandwidthKHz: 250, spreadingFactor: 11, codingRate: 5, pathHashSize: nil),
        RadioPreset(title: "EU 433MHz (Narrow)", frequencyMHz: 433.65, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8, pathHashSize: nil),
        RadioPreset(title: "Hungary", frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: 2),
        RadioPreset(title: "Netherlands", frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: nil),
        RadioPreset(title: "Netherlands (Limburg)", frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8, pathHashSize: 2),
        RadioPreset(title: "New Zealand (Narrow)", frequencyMHz: 917.375, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: 2),
        RadioPreset(title: "New Zealand (Gisborne)", frequencyMHz: 917.375, bandwidthKHz: 250, spreadingFactor: 11, codingRate: 5, pathHashSize: 1),
        RadioPreset(title: "Portugal 433", frequencyMHz: 433.375, bandwidthKHz: 62.5, spreadingFactor: 9, codingRate: 6, pathHashSize: nil),
        RadioPreset(title: "Portugal 868", frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 6, pathHashSize: nil),
        RadioPreset(title: "Slovakia", frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: 2),
        RadioPreset(title: "Switzerland", frequencyMHz: 869.618, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 8, pathHashSize: nil),
        RadioPreset(title: "USA", frequencyMHz: 910.525, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: nil),
        RadioPreset(title: "USA - Southern California", frequencyMHz: 927.875, bandwidthKHz: 62.5, spreadingFactor: 7, codingRate: 5, pathHashSize: 3),
        RadioPreset(title: "Vietnam (Narrow)", frequencyMHz: 920.25, bandwidthKHz: 62.5, spreadingFactor: 8, codingRate: 5, pathHashSize: nil),
        RadioPreset(title: "Vietnam (Deprecated)", frequencyMHz: 920.25, bandwidthKHz: 250, spreadingFactor: 11, codingRate: 5, pathHashSize: nil),
    ]
}
