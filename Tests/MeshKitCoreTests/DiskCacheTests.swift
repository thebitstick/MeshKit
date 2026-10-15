import Foundation
import Testing
@testable import MeshKitCore

@Suite struct DiskCacheTests {
    private struct Offline: Error {}

    private func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diskcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aFreshAnswerIsUsedAndSaved() async throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try await DiskCache.fetch("list", in: dir) { Data("new".utf8) }
        #expect(data == Data("new".utf8))
        #expect(DiskCache.read("list", in: dir) == Data("new".utf8))
    }

    @Test func theSavedCopyAnswersWhenTheNetworkDoesNot() async throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        DiskCache.write(Data("saved".utf8), for: "list", in: dir)
        let data = try await DiskCache.fetch("list", in: dir) { throw Offline() }
        #expect(data == Data("saved".utf8))
    }

    @Test func withNothingSavedTheFailureIsReported() async throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: Offline.self) { _ = try await DiskCache.fetch("list", in: dir) { throw Offline() } }
    }

    @Test func aCopyOlderThanAMonthIsNotUsedAndIsPruned() throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        DiskCache.write(Data("old".utf8), for: "list", in: dir)
        let later = Date().addingTimeInterval(DiskCache.lifetime + 3600)
        #expect(DiskCache.read("list", in: dir, now: later) == nil)
        DiskCache.prune(directories: [dir], now: later)
        #expect(DiskCache.read("list", in: dir) == nil)
        DiskCache.write(Data("kept".utf8), for: "other", in: dir)
        DiskCache.prune(directories: [dir])
        #expect(DiskCache.read("other", in: dir) == Data("kept".utf8))
    }
}

@Suite struct DiskCacheUseTests {
    private struct Offline: Error {}

    private func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diskcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func usingAFileKeepsItForAnotherMonth() throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        DiskCache.write(Data("x".utf8), for: "k", in: dir)
        let file = DiskCache.file(for: "k", in: dir)
        let old = Date().addingTimeInterval(-(DiskCache.lifetime - 3600))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        #expect(DiskCache.read("k", in: dir) != nil)
        let modified = try #require(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(Date().timeIntervalSince(modified) < 60)
    }

    @Test func servingASavedCopyIsReportedAndAFreshAnswerClearsIt() async throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        DiskCache.write(Data("saved".utf8), for: "list", in: dir)
        _ = try await DiskCache.fetch("list", in: dir) { throw Offline() }
        #expect(DiskCache.servedStale)
        _ = try await DiskCache.fetch("list", in: dir) { Data("fresh".utf8) }
        #expect(!DiskCache.servedStale)
    }
}
