import MeshKitCore
import SwiftUI

enum FlashPayload {
    case uf2(Data, erase: NRF52EraseImages?)
    case bootloaderUpdate(Data)
    case nrfSerialDFU(NRF52DFUPackage)
    case uf2Restore(Data)
    case esp(ESPFlashJob)
}

struct FlashContext {
    var address: UInt32 = 0
}

struct FlashRequest: Identifiable {
    enum Target { case uf2, esp, nrfSerial }

    let id = UUID()
    let title: String
    let subtitle: String
    let target: Target
    var prepareTitle = "Download the firmware"
    var needsAddress = false
    var offersErase = false
    var eraseDefault = false
    var warning: String?
    var details: [String] = []
    /// Whether the sheet offers to save the board's current firmware first (nRF52 UF2 installs).
    var allowsBackup = true
    /// Shown under the bootloader-drive picker for the drive that is selected.
    var volumeNote: (@Sendable (UF2Volume) -> String?)?
    let prepare: @Sendable (FlashContext) async throws -> FlashPayload

    // MARK: MeshCore

    @MainActor
    static func meshCore(_ group: FirmwareBoardGroup, connection: MeshCoreConnection?,
                         release: GitHubRelease, mode: MeshCoreInstallMode, model: AppModel) -> FlashRequest? {
        guard let build = group.build(for: connection), let artifact = build.fullImage else { return nil }
        let role = build.role.title
        let via = connection.map { " · \($0.title)" } ?? ""
        let isUF2 = artifact.kind == .uf2
        var request = FlashRequest(
            title: "Install \(group.title)",
            subtitle: "MeshCore \(role)\(via) · v\(build.version) · \(mode.rawValue)",
            target: isUF2 ? .uf2 : .esp,
            details: [artifact.asset.name],
            prepare: { _ in
                guard let url = await model.firmware.download(artifact), let data = try? Data(contentsOf: url) else {
                    throw FlashPrepareError(message: await model.firmware.error ?? "Download failed")
                }
                if isUF2 { return .uf2(data, erase: mode == .fresh ? try await meshtasticEraseImages() : nil) }
                return .esp(mode == .fresh
                    ? MeshCoreImage.cleanJob(merged: data, name: artifact.asset.name)
                    : try MeshCoreImage.updateJob(merged: data, name: artifact.asset.name))
            })
        let kept = "The firmware is replaced and the node's settings and identity are kept."
        if isUF2 {
            request.warning = mode == .fresh
                ? "A clean install first runs Meshtastic's nRF52 erase tool, which wipes the board's firmware, identity key and settings, then installs this firmware. The erase tool is downloaded from Meshtastic's latest release. There is no flash backup for nRF52 boards."
                : kept
        } else {
            request.warning = mode == .fresh
                ? "A clean install erases the whole flash, including the node's identity key and settings. A backup of the current flash is saved first unless you turn that off."
                : "\(kept) A backup of the current flash is saved first unless you turn that off."
        }
        return request
    }

    // MARK: Meshtastic

    static func meshtastic(_ board: MeshtasticBoard, release: MeshtasticRelease, mode: MeshtasticInstallMode) -> FlashRequest {
        let catalog = MeshtasticCatalog()
        var request = FlashRequest(
            title: "Install \(board.displayName)",
            subtitle: "Meshtastic \(release.version) (\(release.channel.rawValue)) · \(mode.rawValue)",
            target: board.isNRF52 ? .uf2 : .esp,
            prepareTitle: "Fetch the firmware files",
            prepare: { _ in
                let package = try catalog.package(for: board, in: release)
                if board.isNRF52 { return .uf2(try await package.uf2Image(), erase: mode == .fresh ? try await catalog.nrf52EraseImages(in: release) : nil) }
                return .esp(try await package.espJob(mode: mode))
            })
        if board.isESP32 {
            request.warning = mode == .fresh
                ? "A clean install erases the whole flash, including your settings, channels and keys. A backup of the current flash is saved first unless you turn that off."
                : "The firmware is replaced and your settings are kept. A backup of the current flash is saved first unless you turn that off."
        } else {
            request.warning = mode == .fresh
                ? "A clean install first runs Meshtastic's nRF52 erase tool, which wipes the board's firmware, settings, channels and keys, then installs this firmware. There is no flash backup for nRF52 boards."
                : "The firmware is replaced and your settings are kept."
        }
        return request
    }

    // MARK: Serial DFU

    private static let serialDFUWarning = "MeshKit restarts the board into serial DFU over USB, so no reset button or bootloader drive is needed, then sends the firmware package. It takes about a minute and keeps the board's settings. Keep the board plugged in until it finishes. There is no flash backup for nRF52 boards."

    @MainActor
    static func meshCoreSerialDFU(_ group: FirmwareBoardGroup, connection: MeshCoreConnection?, model: AppModel) -> FlashRequest? {
        guard let build = group.build(for: connection), let artifact = build.artifacts.first(where: { $0.kind == .nrfDFUPackage }) else { return nil }
        return FlashRequest(
            title: "Install \(group.title) over serial DFU",
            subtitle: "MeshCore \(build.role.title)\(connection.map { " · \($0.title)" } ?? "") · v\(build.version)",
            target: .nrfSerial, warning: serialDFUWarning, details: [artifact.asset.name],
            prepare: { _ in
                guard let url = await model.firmware.download(artifact), let data = try? Data(contentsOf: url) else {
                    throw FlashPrepareError(message: await model.firmware.error ?? "Download failed")
                }
                return .nrfSerialDFU(try await NRF52DFUPackage.read(zip: data))
            })
    }

    static func meshtasticSerialDFU(_ board: MeshtasticBoard, release: MeshtasticRelease) -> FlashRequest {
        let catalog = MeshtasticCatalog()
        return FlashRequest(
            title: "Install \(board.displayName) over serial DFU",
            subtitle: "Meshtastic \(release.version) (\(release.channel.rawValue))",
            target: .nrfSerial, prepareTitle: "Fetch the DFU package", warning: serialDFUWarning,
            prepare: { _ in
                let data = try await catalog.package(for: board, in: release).dfuPackage()
                return .nrfSerialDFU(try await NRF52DFUPackage.read(zip: data))
            })
    }

    // MARK: Bootloader

    static func dfuBootloaderFix(boardID: String, boardName: String) -> FlashRequest {
        FlashRequest(
            title: "Install DFU bootloader fix",
            subtitle: "OTAFIX bootloader for \(boardName)",
            target: .uf2, prepareTitle: "Download the bootloader update",
            warning: "This replaces the board's bootloader with the OTAFIX build, which makes Bluetooth firmware updates more reliable. It is for \(boardName) only: the wrong file can leave a board that needs a hardware programmer to recover. Keep the board plugged in until it reboots. Your firmware and settings are not touched.",
            volumeNote: { volume in
                if let version = OTAFix.installedVersion(inBootloader: volume.bootloader) {
                    return "\(volume.name) already runs the OTAFIX bootloader (\(version)). Install again only to move to the newest build."
                }
                return "\(volume.name) runs the standard bootloader: \(volume.bootloader.prefix(40))…"
            },
            prepare: { _ in
                let update = try await OTAFix.latestUpdate(for: boardID)
                let url = try await OTAFix.download(update)
                return .bootloaderUpdate(try Data(contentsOf: url))
            })
    }

    // MARK: Saved and local images

    static func restoreNRF52(_ entry: NRF52BackupStore.Entry) -> FlashRequest {
        FlashRequest(
            title: "Restore \(entry.board) firmware",
            subtitle: "Saved \(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.size >> 10) KB",
            target: .uf2, prepareTitle: "Read the saved image",
            warning: "This puts the SoftDevice and application back as they were when the image was saved. The bootloader is not touched. Settings stored after the image was saved are not part of it.",
            allowsBackup: false,
            prepare: { _ in .uf2Restore(try Data(contentsOf: entry.url)) })
    }

    static func restore(_ entry: FlashBackupStore.Entry) -> FlashRequest {
        FlashRequest(
            title: "Restore \(entry.chip) flash image",
            subtitle: "Saved \(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.size >> 20) MB",
            target: .esp, prepareTitle: "Read the saved image",
            warning: "This overwrites everything on the board with the saved image, including its settings and identity.",
            prepare: { _ in .esp(.single(try Data(contentsOf: entry.url), name: entry.url.lastPathComponent)) })
    }

    static func localFile(_ url: URL) -> FlashRequest {
        let isUF2 = url.pathExtension.lowercased() == "uf2"
        var request = FlashRequest(
            title: "Install \(url.lastPathComponent)",
            subtitle: isUF2 ? "UF2 image from disk" : "Raw image from disk",
            target: isUF2 ? .uf2 : .esp, prepareTitle: "Read the file",
            prepare: { ctx in
                let data = try Data(contentsOf: url)
                return isUF2 ? .uf2(data, erase: nil) : .esp(.single(data, at: ctx.address, name: url.lastPathComponent))
            })
        request.needsAddress = !isUF2
        if !isUF2 {
            request.warning = "A raw .bin has no layout information. Full (\"merged\" or \"factory\") images go at 0x0; application-only images usually go at 0x10000. A wrong address can leave the board unbootable."
        }
        return request
    }
}

struct FlashPrepareError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func meshtasticEraseImages() async throws -> NRF52EraseImages {
    let catalog = MeshtasticCatalog()
    let releases = try await catalog.releases(limit: 30)
    guard let release = releases.first(where: { $0.channel == .stable }) ?? releases.first else {
        throw FlashPrepareError(message: "Couldn't find a Meshtastic release to take the erase tool from.")
    }
    return try await catalog.nrf52EraseImages(in: release)
}
