import MeshKitCore
import SwiftUI

enum FirmwareVendor: String, CaseIterable, Identifiable {
    case meshcore = "MeshCore", meshtastic = "Meshtastic"
    var id: String { rawValue }
}

@MainActor @Observable
final class FirmwareModel {
    let vendor: FirmwareVendor
    var isLoading = false
    var error: String?
    var query = ""

    var role: MeshCoreRole = .companion
    var releases: [GitHubRelease] = []
    var selectedTag: String?
    var selectedBoardID: String?
    var preferredConnection: MeshCoreConnection = .ble
    var mcMode: MeshCoreInstallMode = .update
    var sources: [FirmwareSource] = FirmwareSourceStore.load()
    var sourceID: String?

    var channel: MeshtasticChannel = .stable
    var mtReleases: [MeshtasticRelease] = []
    var mtSelectedVersion: String?
    var mtBoards: [MeshtasticBoard] = []
    var mtSelectedSlug: String?
    var mtMode: MeshtasticInstallMode = .update
    var showCommunityBoards = false
    var autoSelect: String?

    var downloaded: [Int: URL] = [:]
    var downloading: Set<Int> = []

    init(vendor: FirmwareVendor) { self.vendor = vendor }

    private var client: ReleaseClient { source.map { ReleaseClient(repository: $0.repository) } ?? ReleaseClient() }
    private let catalog = MeshtasticCatalog()
    private var mtAllReleases: [MeshtasticRelease] = []

    /// Only the newest load may update the screen: a slow earlier request must not overwrite what the person
    /// has since switched to.
    private var loadGeneration = 0

    /// GitHub allows 60 unauthenticated API requests an hour, so lists already fetched are reused for a few minutes.
    private var releaseCache: [String: (fetched: Date, releases: [GitHubRelease])] = [:]
    private var mtBoardCache: [String: [MeshtasticBoard]] = [:]
    private static let cacheLifetime: TimeInterval = 10 * 60

    // MARK: MeshCore

    var source: FirmwareSource? { sources.first { $0.id == sourceID } }

    func reloadSources() {
        sources = FirmwareSourceStore.load()
        guard sourceID != nil, source == nil else { return }
        sourceID = nil; selectedTag = nil; selectedBoardID = nil
        Task { await load() }
    }

    var selectedRelease: GitHubRelease? { releases.first { $0.tagName == selectedTag } ?? releases.first }

    var boardGroups: [FirmwareBoardGroup] {
        guard let release = selectedRelease else { return [] }
        let groups = FirmwareBoardGroup.groups(from: ReleaseClient.builds(from: release, role: role, source: source?.id))
        guard !query.isEmpty else { return groups }
        return groups.compactMap { g in FuzzyMatch.score(query, in: [g.title, g.board, g.maker ?? ""]).map { (g, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var selectedGroup: FirmwareBoardGroup? { boardGroups.first { $0.id == selectedBoardID } }

    func effectiveConnection(for group: FirmwareBoardGroup) -> MeshCoreConnection? {
        group.connections.contains(preferredConnection) ? preferredConnection : group.connections.first
    }

    // MARK: Meshtastic

    /// Releases in the chosen channel. Stable includes nothing newer than itself; Beta and Alpha show their own.
    var mtChannelReleases: [MeshtasticRelease] { mtAllReleases.filter { $0.channel == channel } }
    var mtSelectedRelease: MeshtasticRelease? { mtChannelReleases.first { $0.version == mtSelectedVersion } ?? mtChannelReleases.first }

    var mtVisibleBoards: [MeshtasticBoard] {
        let eligible = mtBoards.filter { b in
            guard b.isFlashable else { return false }
            return showCommunityBoards || ((b.supportLevel ?? 9) <= 1 && b.activelySupported)
        }
        guard !query.isEmpty else { return eligible }
        return eligible.compactMap { b in FuzzyMatch.score(query, in: [b.displayName, b.slug, b.vendor ?? ""]).map { (b, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var mtSelectedBoard: MeshtasticBoard? { mtBoards.first { $0.slug == mtSelectedSlug } }

    // MARK: Loading

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        defer { if generation == loadGeneration { isLoading = false } }

        switch vendor {
        case .meshcore:
            let role = role
            let key = "\(sourceID ?? "")/\(role.rawValue)"
            do {
                let fetched: [GitHubRelease]
                if let cached = releaseCache[key], Date().timeIntervalSince(cached.fetched) < Self.cacheLifetime {
                    fetched = cached.releases
                } else {
                    fetched = try await client.releases(for: role, limit: source == nil ? 4 : 8)
                    releaseCache[key] = (Date(), fetched)
                }
                guard generation == loadGeneration else { return }
                releases = fetched
                if selectedRelease == nil || !releases.contains(where: { $0.tagName == selectedTag }) {
                    selectedTag = releases.first?.tagName
                }
            } catch {
                guard generation == loadGeneration else { return }
                releases = []
                self.error = error.localizedDescription
            }
        case .meshtastic:
            do {
                if mtAllReleases.isEmpty { mtAllReleases = try await catalog.releases(limit: 30) }
                guard generation == loadGeneration else { return }
                try await loadMeshtasticBoards()
            } catch {
                guard generation == loadGeneration else { return }
                mtAllReleases = []; mtBoards = []
                self.error = error.localizedDescription
            }
        }
        guard generation == loadGeneration else { return }
        applyAutoSelect()
    }

    func loadMeshtasticBoards() async throws {
        guard let release = mtSelectedRelease else { mtBoards = []; return }
        mtSelectedVersion = release.version
        if let cached = mtBoardCache[release.version] {
            mtBoards = cached
        } else {
            let boards = try await catalog.boards(in: release)
            mtBoardCache[release.version] = boards
            guard mtSelectedRelease?.version == release.version else { return }
            mtBoards = boards
        }
        if mtSelectedBoard == nil { mtSelectedSlug = nil }
    }

    func reloadMeshtasticBoards() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do { try await loadMeshtasticBoards() } catch { mtBoards = []; self.error = error.localizedDescription }
    }

    private func applyAutoSelect() {
        guard let pick = autoSelect else { return }
        switch vendor {
        case .meshcore:
            if let g = boardGroups.first(where: { $0.title.lowercased().contains(pick) || $0.board.lowercased().contains(pick) }) { selectedBoardID = g.id; autoSelect = nil }
        case .meshtastic:
            if let b = mtVisibleBoards.first(where: { $0.slug.lowercased().contains(pick) || $0.displayName.lowercased().contains(pick) }) { mtSelectedSlug = b.slug; autoSelect = nil }
        }
    }

    func refresh() async {
        mtAllReleases = []; releaseCache = [:]; mtBoardCache = [:]
        await load()
    }

    // MARK: Downloads (MeshCore)

    func download(_ artifact: FirmwareArtifact) async -> URL? {
        downloading.insert(artifact.id)
        defer { downloading.remove(artifact.id) }
        do {
            let url = try await client.download(artifact)
            downloaded[artifact.id] = url
            return url
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: Requests

    func meshCoreRequest(model: AppModel) -> FlashRequest? {
        guard let group = selectedGroup, let release = selectedRelease else { return nil }
        return .meshCore(group, connection: group.build(for: effectiveConnection(for: group))?.connection,
                         release: release, mode: mcMode, source: source, model: model)
    }

    func meshtasticFileName(board: MeshtasticBoard, release: MeshtasticRelease) -> String {
        let base = "firmware-\(board.slug)-\(release.version)"
        if board.isNRF52 { return base + ".uf2" }
        return base + (mtMode == .fresh ? ".factory.bin" : ".bin")
    }

    func meshCoreSerialDFURequest(model: AppModel) -> FlashRequest? {
        guard let group = selectedGroup else { return nil }
        return .meshCoreSerialDFU(group, connection: group.build(for: effectiveConnection(for: group))?.connection, model: model)
    }

    func meshtasticRequest() -> FlashRequest? {
        guard let board = mtSelectedBoard, let release = mtSelectedRelease else { return nil }
        return .meshtastic(board, release: release, mode: mtMode)
    }
}
