import MeshKitCore
import SwiftUI

enum FlashPayload {
    case uf2(Data, erase: NRF52EraseImages?)
    case bootloaderUpdate(Data)
    case nrfSerialDFU(NRF52DFUPackage)
    case nrfSerialClean(eraser: NRF52DFUPackage, package: NRF52DFUPackage)
    case uf2Restore(Data)
    case esp(ESPFlashJob)
}

struct FlashContext {
    var address: UInt32 = 0
}

/// One short line the sheet shows before an install. Dangers come first, in a tinted box; what is kept and how it works
/// follow in plain rows, so the thing that can hurt is never buried in an explanation.
struct FlashNote: Identifiable {
    enum Kind { case danger, caution, keep, info }
    let kind: Kind
    let text: String
    var id: String { text }

    static func danger(_ text: String) -> FlashNote { .init(kind: .danger, text: text) }
    static func caution(_ text: String) -> FlashNote { .init(kind: .caution, text: text) }
    static func keep(_ text: String) -> FlashNote { .init(kind: .keep, text: text) }
    static func info(_ text: String) -> FlashNote { .init(kind: .info, text: text) }
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
    var notes: [FlashNote] = []
    var details: [String] = []
    /// Whether the sheet offers to save the board's current firmware first (nRF52 UF2 installs).
    var allowsBackup = true
    /// Shown under the bootloader-drive picker for the drive that is selected.
    var volumeNote: (@Sendable (UF2Volume) -> String?)?
    /// What to offer when this one fails, e.g. the bootloader drive after a serial DFU that stopped answering.
    var fallback: (@MainActor () -> FlashRequest?)?
    /// Work to do once the install has finished, such as setting a converted node's name and location.
    /// Gets the path of the serial port the install used, which an ESP32 is still on afterwards.
    var afterFlash: (title: String, run: @Sendable (_ port: String?, _ log: @escaping @Sendable (String) -> Void) async throws -> Void)?
    let prepare: @Sendable (FlashContext) async throws -> FlashPayload

    // MARK: MeshCore

    @MainActor
    static func meshCore(_ group: FirmwareBoardGroup, connection: MeshCoreConnection?,
                         release: GitHubRelease, mode: MeshCoreInstallMode, source: FirmwareSource? = nil, model: AppModel) -> FlashRequest? {
        guard let build = group.build(for: connection), let artifact = build.fullImage else { return nil }
        let role = build.role.title
        let via = connection.map { " · \($0.title)" } ?? ""
        let isUF2 = artifact.kind == .uf2
        var request = FlashRequest(
            title: "Install \(group.title)",
            subtitle: "\(source?.name ?? "MeshCore") \(role)\(via) · v\(build.version) · \(mode.rawValue)",
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
        if mode == .fresh {
            request.notes = [.danger("Erases the \(isUF2 ? "board" : "whole flash"): identity key and settings are lost.")]
            if isUF2 { request.notes.append(.info("Runs Meshtastic's erase tool first (downloaded for you).")) }
        } else {
            request.notes = [.keep("Settings and identity are kept.")]
        }
        if let source {
            request.notes.insert(.caution("From \(source.repository), not the MeshCore project. MeshKit can't vouch for it."), at: 0)
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
        if mode == .fresh {
            request.notes = [.danger("Erases the \(board.isESP32 ? "whole flash" : "board"): settings, channels and keys are lost.")]
            if !board.isESP32 { request.notes.append(.info("Runs Meshtastic's erase tool first.")) }
        } else {
            request.notes = [.keep("Settings, channels and keys are kept.")]
        }
        return request
    }

    // MARK: Serial DFU

    private static func serialNotes(clean: Bool) -> [FlashNote] {
        var notes: [FlashNote] = clean
            ? [.danger("Erases the board: identity key and settings are lost."),
               .info("Loads Meshtastic's erase tool, wipes the board, then sends the firmware. Takes a couple of minutes.")]
            : [.keep("Settings are kept."),
               .info("Restarts the board in update mode over USB. No drive or reset button needed. About a minute.")]
        notes.append(.info("Can't back up the board first. Use Backups ▸ Back up now (it needs the board's drive)."))
        return notes
    }

    /// What goes over serial: the firmware alone for an update, or the erase tool first for a clean install.
    private static func serialPayload(_ package: NRF52DFUPackage, clean: Bool, eraseImages: () async throws -> NRF52EraseImages) async throws -> FlashPayload {
        guard clean else { return .nrfSerialDFU(package) }
        return .nrfSerialClean(eraser: try NRF52DFUPackage.eraseTool(for: package, from: try await eraseImages()), package: package)
    }

    @MainActor
    static func meshCoreSerialDFU(_ group: FirmwareBoardGroup, connection: MeshCoreConnection?, clean: Bool = false, model: AppModel) -> FlashRequest? {
        guard let build = group.build(for: connection), let artifact = build.artifacts.first(where: { $0.kind == .nrfDFUPackage }) else { return nil }
        return FlashRequest(
            title: "Install \(group.title) over USB",
            subtitle: "MeshCore \(build.role.title)\(connection.map { " · \($0.title)" } ?? "") · v\(build.version) · \(clean ? "Clean install" : "Update")",
            target: .nrfSerial, notes: serialNotes(clean: clean), details: [artifact.asset.name],
            prepare: { _ in
                guard let url = await model.firmware.download(artifact), let data = try? Data(contentsOf: url) else {
                    throw FlashPrepareError(message: await model.firmware.error ?? "Download failed")
                }
                return try await serialPayload(try await NRF52DFUPackage.read(zip: data), clean: clean, eraseImages: meshtasticEraseImages)
            })
    }

    static func meshtasticSerialDFU(_ board: MeshtasticBoard, release: MeshtasticRelease, clean: Bool = false) -> FlashRequest {
        let catalog = MeshtasticCatalog()
        return FlashRequest(
            title: "Install \(board.displayName) over USB",
            subtitle: "Meshtastic \(release.version) (\(release.channel.rawValue))\(clean ? " · Clean install" : "")",
            target: .nrfSerial, prepareTitle: "Fetch the firmware", notes: serialNotes(clean: clean),
            prepare: { _ in
                let data = try await catalog.package(for: board, in: release).dfuPackage()
                return try await serialPayload(try await NRF52DFUPackage.read(zip: data), clean: clean, eraseImages: { try await catalog.nrf52EraseImages(in: release) })
            })
    }

    /// Puts a saved firmware back without a drive. Only the application is sent; the board keeps its Bluetooth stack.
    static func restoreNRF52OverSerial(_ entry: NRF52BackupStore.Entry) -> FlashRequest {
        FlashRequest(
            title: "Restore \(entry.board) firmware over USB",
            subtitle: "\(entry.firmware ?? "Firmware") · saved \(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.size >> 10) KB",
            target: .nrfSerial, prepareTitle: "Read the saved image",
            notes: [.caution("Replaces the board's current firmware."),
                    .info("Sends the saved application over USB. The Bluetooth stack and bootloader aren't touched."),
                    .info("Settings saved after this image was made aren't included.")],
            allowsBackup: false,
            prepare: { _ in .nrfSerialDFU(try NRF52DFUPackage.restoring(backup: try Data(contentsOf: entry.url))) })
    }

    // MARK: Bootloader

    static func dfuBootloaderFix(boardID: String, boardName: String) -> FlashRequest {
        FlashRequest(
            title: "Install DFU bootloader fix",
            subtitle: "OTAFIX bootloader for \(boardName)",
            target: .uf2, prepareTitle: "Download the bootloader update",
            notes: [.danger("Only for \(boardName). The wrong file can leave the board unrecoverable without a programmer."),
                    .keep("Your firmware and settings aren't touched."),
                    .info("Makes Bluetooth updates more reliable. Keep the board plugged in until it reboots.")],
            volumeNote: { volume in
                if let version = OTAFix.installedVersion(inBootloader: volume.bootloader) {
                    return "\(volume.name) already has the OTAFIX bootloader (\(version)). Install again only for the newest build."
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
            subtitle: "\(entry.firmware ?? "Firmware") · saved \(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.size >> 10) KB",
            target: .uf2, prepareTitle: "Read the saved image",
            notes: [.caution("Replaces the board's current firmware."),
                    .info("Puts back the Bluetooth stack and application as saved. The bootloader isn't touched."),
                    .info("Settings saved after this image was made aren't included.")],
            allowsBackup: false,
            prepare: { _ in .uf2Restore(try Data(contentsOf: entry.url)) })
    }

    // MARK: Convert

    private static func convertNotes(identity: NodeIdentity?, original: NodeIdentity?, toMeshCore: Bool = false, esp: Bool = false, role: MeshCoreRole = .companion) -> [FlashNote] {
        var notes: [FlashNote] = [.danger("Erases the board: identity key, channels and radio settings are lost.")]
        if esp { notes.append(.keep("A backup of the whole flash is saved first, so you can put it all back.")) }
        if let identity {
            notes.append(.keep("Carried over: \(identity.summary)."))
            if let original, original.name != identity.name {
                let bad = role == .companion || !toMeshCore ? [] : NameLimits.repeaterForbiddenCharacters(in: original.name)
                if !bad.isEmpty {
                    notes.append(.caution("A \(role.title.lowercased()) can't have \(bad.map { "“\($0)”" }.joined(separator: " ")) in its name; \(bad.count == 1 ? "it is" : "they are") replaced with spaces. The name becomes “\(identity.name)”."))
                } else {
                    notes.append(.caution("The name is shortened to \(identity.name.utf8.count) bytes to fit: it was \(original.name.utf8.count)."))
                }
            }
            if identity.hasLocation, toMeshCore {
                notes.append(.info("Location sharing starts off on a new MeshCore install. Turn it on in Configure to advertise it."))
            }
            if identity.exceedsLocationAdvertLimit, toMeshCore, role == .companion {
                notes.append(.info("Over \(NameLimits.meshCoreAdvertised) bytes: if you turn on location sharing, other nodes see only the first \(NameLimits.meshCoreAdvertised)."))
            }
        } else {
            notes.append(.info("Nothing is carried over: no node is connected."))
        }
        notes.append(.info("Takes a couple of minutes. Keep the board plugged in."))
        return notes
    }

    static func convertToMeshtastic(boardName: String, meshtasticSlug: String, isESP32: Bool = false, identity original: NodeIdentity?) -> FlashRequest {
        let identity = original.map { $0.fitted(toBytes: NameLimits.meshtasticLong) }
        let catalog = MeshtasticCatalog()
        var request = FlashRequest(
            title: "Convert \(boardName) to Meshtastic", subtitle: "A clean install of the latest stable Meshtastic",
            target: isESP32 ? .esp : .nrfSerial, prepareTitle: "Fetch Meshtastic",
            notes: convertNotes(identity: identity, original: original, esp: isESP32),
            prepare: { _ in
                let releases = try await catalog.releases(limit: 30)
                guard let release = releases.first(where: { $0.channel == .stable }) ?? releases.first else {
                    throw FlashPrepareError(message: "Couldn't find a Meshtastic release.")
                }
                guard let board = try await catalog.boards(in: release).first(where: { $0.slug.lowercased() == meshtasticSlug.lowercased() }) else {
                    throw FlashPrepareError(message: "Meshtastic \(release.version) has no build for this board.")
                }
                let package = try catalog.package(for: board, in: release)
                if isESP32 { return .esp(try await package.espJob(mode: .fresh)) }
                let data = try await package.dfuPackage()
                return try await serialPayload(try await NRF52DFUPackage.read(zip: data), clean: true, eraseImages: { try await catalog.nrf52EraseImages(in: release) })
            })
        if let identity {
            request.afterFlash = ("Set the name and location", { port, log in
                try await IdentityTransfer.carryOver(identity, toMeshtasticAt: { try await IdentityTransfer.openPort(port) }, logger: log)
            })
        }
        return request
    }

    static func convertToMeshCore(boardName: String, meshCoreSlug: String, role: MeshCoreRole = .companion, isESP32: Bool = false, identity original: NodeIdentity?) -> FlashRequest {
        let identity = original.map { role == .companion ? $0.fitted(toBytes: NameLimits.meshCore) : $0.fittedForRepeater() }
        let roleName = role == .companion ? "USB companion" : role.title.lowercased()
        var request = FlashRequest(
            title: "Convert \(boardName) to MeshCore", subtitle: "A clean install of the latest stable MeshCore \(roleName)",
            target: isESP32 ? .esp : .nrfSerial, prepareTitle: "Fetch MeshCore",
            notes: convertNotes(identity: identity, original: original, toMeshCore: true, esp: isESP32, role: role),
            prepare: { _ in
                let client = ReleaseClient()
                guard let release = try await client.releases(for: role, limit: 1).first else {
                    throw FlashPrepareError(message: "Couldn't find a MeshCore release.")
                }
                let groups = FirmwareBoardGroup.groups(from: ReleaseClient.builds(from: release, role: role))
                let group = groups.first(where: { $0.board.lowercased() == meshCoreSlug.lowercased() })
                let build = role == .companion ? group?.build(for: .usb) : group?.build(for: nil)
                if isESP32 {
                    guard let artifact = build?.fullImage else {
                        throw FlashPrepareError(message: "MeshCore publishes no \(roleName) for this board, so there is nothing to convert to.")
                    }
                    return .esp(MeshCoreImage.cleanJob(merged: try Data(contentsOf: try await client.download(artifact)), name: artifact.asset.name))
                }
                guard let artifact = build?.artifacts.first(where: { $0.kind == .nrfDFUPackage }) else {
                    throw FlashPrepareError(message: "MeshCore publishes no \(roleName) for this board, so there is nothing to convert to.")
                }
                let data = try Data(contentsOf: try await client.download(artifact))
                return try await serialPayload(try await NRF52DFUPackage.read(zip: data), clean: true, eraseImages: meshtasticEraseImages)
            })
        if let identity {
            request.afterFlash = ("Set the name and location", { port, log in
                let open: @Sendable () async throws -> ByteTransport = { try await IdentityTransfer.openPort(port) }
                if role == .companion { try await IdentityTransfer.carryOver(identity, toCompanionAt: open, logger: log) }
                else { try await IdentityTransfer.carryOver(identity, toRepeaterAt: open, logger: log) }
            })
        }
        return request
    }

    static let espBackup = FlashRequest(
        title: "Back up the board's flash",
        subtitle: "A full copy of the flash, saved in the Backups tab",
        target: .esp, prepareTitle: "Prepare",
        notes: [.info("Reads the whole flash, including the identity key. Nothing is written. A minute or two.")],
        prepare: { _ in .esp(.backupOnly) })

    static func restore(_ entry: FlashBackupStore.Entry) -> FlashRequest {
        FlashRequest(
            title: "Restore \(entry.chip) flash image",
            subtitle: "Saved \(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.size >> 20) MB",
            target: .esp, prepareTitle: "Read the saved image",
            notes: [.danger("Overwrites everything on the board with the saved image."), .info("Settings and identity come back with it.")],
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
            request.notes = [.danger("A wrong address can leave the board unbootable."),
                             .info("Full (merged or factory) images go at 0x0. Application-only images usually go at 0x10000.")]
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
