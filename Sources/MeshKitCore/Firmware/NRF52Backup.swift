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
        public var id: URL { url }
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

    public static func list(in directory: URL = directory) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url -> Entry? in
            guard url.pathExtension == "uf2", let split = url.deletingPathExtension().lastPathComponent.range(of: "_", options: .backwards),
                  let date = stamp.date(from: String(url.deletingPathExtension().lastPathComponent[split.upperBound...])) else { return nil }
            let board = String(url.deletingPathExtension().lastPathComponent[..<split.lowerBound])
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Entry(url: url, board: board, date: date, size: size)
        }
        .sorted { $0.date > $1.date }
    }
}
