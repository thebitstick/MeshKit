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
    var usingSavedLists = false
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
        usingSavedLists = DiskCache.servedStale
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

    /// The best board in the current list for a name such as "Heltec T096" or "Seeed Wio Tracker L1", if any matches well.
    func bestBoard(matching hint: String) -> String? {
        let key = "\(vendor.rawValue)|\(selectedRelease?.tagName ?? "")|\(role.rawValue)|\(sourceID ?? "")|\(mtSelectedVersion ?? "")|\(mtBoards.count)|\(showCommunityBoards)|\(hint)"
        if let known = boardMatches[key] { return known }
        let result = computeBestBoard(matching: hint)
        boardMatches[key] = .some(result)
        return result
    }

    @ObservationIgnored private var boardMatches: [String: String?] = [:]

    private func computeBestBoard(matching hint: String) -> String? {
        switch vendor {
        case .meshcore:
            let all = selectedRelease.map { FirmwareBoardGroup.groups(from: ReleaseClient.builds(from: $0, role: role, source: source?.id)) } ?? []
            return all.compactMap { g in FuzzyMatch.score(hint, in: [g.title, g.board]).map { (g.id, $0) } }.max { $0.1 < $1.1 }?.0
        case .meshtastic:
            return mtVisibleBoards.compactMap { b in FuzzyMatch.score(hint, in: [b.displayName, b.slug]).map { (b.slug, $0) } }.max { $0.1 < $1.1 }?.0
        }
    }

    func selectBoard(matching hint: String) {
        guard let id = bestBoard(matching: hint) else { return }
        query = ""
        switch vendor {
        case .meshcore: selectedBoardID = id
        case .meshtastic: mtSelectedSlug = id
        }
    }

    var hasSelection: Bool { vendor == .meshcore ? selectedBoardID != nil : mtSelectedSlug != nil }

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
        return .meshCoreSerialDFU(group, connection: group.build(for: effectiveConnection(for: group))?.connection, clean: mcMode == .fresh, model: model)
    }

    /// A nRF52 board that is plugged in and running is installed over its serial port, with the bootloader drive as the
    /// fallback; with a drive already mounted, or on other boards, the usual install.
    func meshCoreInstallRequest(model: AppModel) -> FlashRequest? {
        guard let group = selectedGroup, let build = group.build(for: effectiveConnection(for: group)), build.isUF2,
              build.artifacts.contains(where: { $0.kind == .nrfDFUPackage }), model.uf2Volumes.isEmpty, !model.dfuCandidatePorts.isEmpty,
              var serial = meshCoreSerialDFURequest(model: model) else { return withMismatchNote(meshCoreRequest(model: model), model: model) }
        serial.fallback = { [unowned model] in model.firmware.meshCoreRequest(model: model) }
        return withMismatchNote(serial, model: model)
    }

    /// A warning at the top of the sheet when the board that is plugged in looks like a different one from the firmware's.
    /// Installing over USB checks only the Bluetooth stack, not the board, so this is the one guard against the wrong file.
    private func withMismatchNote(_ request: FlashRequest?, model: AppModel) -> FlashRequest? {
        guard var request, let detected = model.detectedBoard, let match = bestBoard(matching: detected), match != (vendor == .meshcore ? selectedBoardID : mtSelectedSlug) else { return request }
        let chosen = vendor == .meshcore ? selectedGroup?.title : mtSelectedBoard?.displayName
        request.notes.insert(.danger("This firmware is for \(chosen ?? "another board"), but the board plugged in looks like \(detected)."), at: 0)
        return request
    }

    func meshtasticInstallRequest(model: AppModel) -> FlashRequest? {
        guard let board = mtSelectedBoard, let release = mtSelectedRelease, board.isNRF52, model.uf2Volumes.isEmpty, !model.dfuCandidatePorts.isEmpty else {
            return withMismatchNote(meshtasticRequest(), model: model)
        }
        var serial = FlashRequest.meshtasticSerialDFU(board, release: release, clean: mtMode == .fresh)
        serial.fallback = { [unowned model] in model.firmware.meshtasticRequest() }
        return withMismatchNote(serial, model: model)
    }

    func meshtasticRequest() -> FlashRequest? {
        guard let board = mtSelectedBoard, let release = mtSelectedRelease else { return nil }
        return .meshtastic(board, release: release, mode: mtMode)
    }
}
