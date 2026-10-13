import Foundation

public struct ESPStubImage: Sendable {
    public let text: [UInt8]
    public let textStart: UInt32
    public let entry: UInt32
    public let data: [UInt8]?
    public let dataStart: UInt32?

    private struct Raw: Decodable {
        let text: Data
        let textStart: UInt32
        let entry: UInt32
        let data: Data?
        let dataStart: UInt32?
    }

    public static func load(for chip: ESPChip) throws -> ESPStubImage {
        guard let url = Bundle.module.url(forResource: chip.stubName, withExtension: "json", subdirectory: "Stubs") else {
            throw ESPError.stubUnavailable(chip.rawValue)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try decoder.decode(Raw.self, from: Data(contentsOf: url))
        return ESPStubImage(text: [UInt8](raw.text), textStart: raw.textStart, entry: raw.entry,
                            data: raw.data.map([UInt8].init), dataStart: raw.dataStart)
    }
}
