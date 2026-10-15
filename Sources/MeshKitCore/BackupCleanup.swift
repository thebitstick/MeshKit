import Foundation

/// Everything MeshKit saves for the person: flash images, nRF52 firmware images and settings snapshots. Deleting it only
/// removes the files MeshKit itself wrote, one level down in its own folders.
public enum BackupCleanup {
    public struct Summary: Equatable, Sendable {
        public var files = 0
        public var bytes = 0
        public var isEmpty: Bool { files == 0 }
        public var text: String {
            isEmpty ? "No saved backups." : "\(files) \(files == 1 ? "file" : "files"), \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
        }
    }

    public static var directories: [URL] { [FlashBackupStore.directory, NRF52BackupStore.directory, SnapshotStore.directory] }

    private static let kinds: Set<String> = ["bin", "uf2", "json"]

    private static func files(in directories: [URL]) -> [(url: URL, size: Int)] {
        directories.flatMap { directory -> [(URL, Int)] in
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
            return urls.compactMap { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true, kinds.contains(url.pathExtension.lowercased()) else { return nil }
                return (url, values?.fileSize ?? 0)
            }
        }
    }

    public static func summary(in directories: [URL] = directories) -> Summary {
        let found = files(in: directories)
        return Summary(files: found.count, bytes: found.reduce(0) { $0 + $1.size })
    }

    @discardableResult
    public static func deleteAll(in directories: [URL] = directories) -> Summary {
        var removed = Summary()
        for (url, size) in files(in: directories) where (try? FileManager.default.removeItem(at: url)) != nil {
            removed.files += 1; removed.bytes += size
        }
        return removed
    }
}
