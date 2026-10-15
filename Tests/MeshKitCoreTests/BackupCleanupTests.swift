import Foundation
import Testing
@testable import MeshKitCore

@Suite struct BackupCleanupTests {
    private func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func countsAndRemovesOnlyBackupFiles() throws {
        let a = try temporary(), b = try temporary()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        try Data(repeating: 1, count: 1000).write(to: a.appendingPathComponent("flash.bin"))
        try Data(repeating: 2, count: 500).write(to: b.appendingPathComponent("board.uf2"))
        try Data("{}".utf8).write(to: b.appendingPathComponent("settings.json"))
        try Data("keep".utf8).write(to: a.appendingPathComponent("notes.txt"))
        let nested = a.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: nested.appendingPathComponent("inner.bin"))

        #expect(BackupCleanup.summary(in: [a, b]) == BackupCleanup.Summary(files: 3, bytes: 1502))
        let removed = BackupCleanup.deleteAll(in: [a, b])
        #expect(removed.files == 3 && removed.bytes == 1502)
        #expect(BackupCleanup.summary(in: [a, b]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("notes.txt").path))
        #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("inner.bin").path))
    }

    @Test func aMissingFolderIsSimplyEmpty() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nothing-\(UUID().uuidString)")
        #expect(BackupCleanup.summary(in: [missing]).isEmpty && BackupCleanup.summary(in: [missing]).text == "No saved backups.")
        #expect(BackupCleanup.deleteAll(in: [missing]).isEmpty)
    }
}
