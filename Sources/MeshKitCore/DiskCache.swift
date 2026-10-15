import CryptoKit
import Foundation

/// Release lists and firmware files kept for up to a month, so installs still work with a slow connection or none.
/// Lists are always fetched fresh when the network answers; the saved copy is only used when it doesn't.
public enum DiskCache {
    public static let lifetime: TimeInterval = 30 * 24 * 3600

    public static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MeshKit/web", isDirectory: true)
    }

    static func file(for key: String, in directory: URL) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    public static func read(_ key: String, in directory: URL = directory, now: Date = .now) -> Data? {
        let url = file(for: key, in: directory)
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              now.timeIntervalSince(modified) <= lifetime, let data = try? Data(contentsOf: url) else { return nil }
        touch(url)
        return data
    }

    /// Marks a file as used now, so a month is counted from the last use and not from the download.
    public static func touch(_ url: URL, now: Date = .now) {
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    private static let staleLock = NSLock()
    nonisolated(unsafe) private static var stale = false

    /// True when the last list was served from the saved copy because the network failed.
    public static var servedStale: Bool { staleLock.lock(); defer { staleLock.unlock() }; return stale }

    private static func setStale(_ value: Bool) { staleLock.lock(); stale = value; staleLock.unlock() }

    public static func write(_ data: Data, for key: String, in directory: URL = directory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: key, in: directory), options: .atomic)
    }

    /// The network's answer, saved; or, when the network fails, the last answer saved within the month.
    public static func fetch(_ key: String, in directory: URL = directory, network: () async throws -> Data) async throws -> Data {
        do {
            let data = try await network()
            write(data, for: key, in: directory)
            setStale(false)
            return data
        } catch {
            if let saved = read(key, in: directory) { setStale(true); return saved }
            throw error
        }
    }

    /// Removes anything older than the lifetime from the saved lists and downloaded firmware.
    public static func prune(directories: [URL] = [directory, ReleaseClient.cacheDirectory], now: Date = .now) {
        for root in directories {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true, let modified = values?.contentModificationDate, now.timeIntervalSince(modified) > lifetime else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// How much the saved lists and downloaded firmware take, as text for Settings.
    public static func sizeText(directories: [URL] = [directory, ReleaseClient.cacheDirectory]) -> String {
        var total = 0
        for root in directories {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
            }
        }
        return total == 0 ? "None" : ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: ReleaseClient.cacheDirectory)
    }
}
