import Foundation

/// Copies of an nRF52 board's firmware (SoftDevice and application, as the bootloader's `CURRENT.UF2` presents them),
/// saved before an install so the board can be put back.
public enum NRF52BackupStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshKit/NRF52Backups", isDirectory: true)
    }

    public struct Entry: Identifiable, Hashable, Sendable {
        public let url: URL
        public let board: String
        public let date: Date
        public let size: Int
        /// What the image holds, read from the version strings inside it, e.g. "MeshCore v1.17.1 (d929643)" or "Meshtastic 2.7.26 (54e0d8d)".
        public let firmware: String?
        public var id: URL { url }
    }

    /// An nRF52 image only has the board's firmware, so the version strings in it are the way to tell what a backup is.
    /// A board that was changed from one firmware to a smaller one still holds pages of the first, so the match at the
    /// lowest address is taken as the firmware and the other is reported as left over.
    public static func describe(_ image: Data) -> String? {
        var found: [(address: UInt32, name: String, version: String)] = []
        let meshCore = #/\bv(\d+\.\d+\.\d+)-([0-9a-f]{7})\b/#
        let meshtastic = #/\b(\d+\.\d+\.\d+)\.([0-9a-f]{7})\b/#
        var offset = 0
        while offset + 512 <= image.count {
            let block = image.subdata(in: offset..<offset + 512)
            offset += 512
            let address = block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
            let size = Int(block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) })
            guard size > 0, size <= 476 else { continue }
            let text = String(decoding: block[32..<32 + size].map { $0 < 0x20 || $0 > 0x7e ? UInt8(ascii: " ") : $0 }, as: UTF8.self)
            for m in text.matches(of: meshCore) { found.append((address, "MeshCore", "v\(m.1) (\(m.2))")) }
            for m in text.matches(of: meshtastic) { found.append((address, "Meshtastic", "\(m.1) (\(m.2))")) }
        }
        found.sort { $0.address < $1.address }
        guard let first = found.first else { return nil }
        let label = "\(first.name) \(first.version)"
        guard let other = found.first(where: { $0.name != first.name }) else { return label }
        return "\(label), with leftovers of \(other.name) \(other.version)"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    @discardableResult
    public static func save(_ image: Data, board: String, date: Date = .now, in directory: URL = directory) throws -> URL {
        _ = try UF2.inspect(image)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(ReleaseClient.safeComponent(board.isEmpty ? "nRF52" : board))_\(stamp.string(from: date)).uf2"
        let url = directory.appendingPathComponent(name)
        try image.write(to: url)
        return url
    }

    private static let labels = LabelCache()

    /// `readLabels: false` returns at once with the labels already known.
    public static func list(in directory: URL = directory, readLabels: Bool = true) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url -> Entry? in
            guard url.pathExtension == "uf2", let split = url.deletingPathExtension().lastPathComponent.range(of: "_", options: .backwards),
                  let date = stamp.date(from: String(url.deletingPathExtension().lastPathComponent[split.upperBound...])) else { return nil }
            let board = String(url.deletingPathExtension().lastPathComponent[..<split.lowerBound])
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Entry(url: url, board: board, date: date, size: size, firmware: readLabels ? labels.label(for: url, compute: describe) : (labels.cached(for: url) ?? nil))
        }
        .sorted { $0.date > $1.date }
    }
}
