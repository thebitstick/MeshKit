import MeshKitCore
import SwiftUI

struct FirmwareView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var fw = model.firmware
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    switch fw.vendor {
                    case .meshcore: MeshCoreControls()
                    case .meshtastic: MeshtasticControls()
                    }
                    if let board = model.detectedBoard {
                        DetectedBoardStrip(name: board, connected: model.session != nil, canShow: fw.bestBoard(matching: board) != nil) { fw.selectBoard(matching: board) }
                    }
                    if fw.usingSavedLists {
                        Label("Offline: showing the lists saved earlier.", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    TextField("Filter boards", text: $fw.query).textFieldStyle(.roundedBorder).accessibilityLabel("Filter boards")
                }
                .padding(12)
                Divider()
                Group {
                    if fw.isLoading {
                        ProgressView("Fetching releases…").frame(maxHeight: .infinity)
                    } else if let error = fw.error {
                        ContentUnavailableView {
                            Label("Couldn't load releases", systemImage: "wifi.exclamationmark")
                        } description: { Text(error) } actions: {
                            Button("Retry") { Task { await fw.refresh() } }
                        }
                    } else {
                        switch fw.vendor {
                        case .meshcore: MeshCoreBoardList()
                        case .meshtastic: MeshtasticBoardList()
                        }
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 460, maxHeight: .infinity)

            Group {
                switch fw.vendor {
                case .meshcore:
                    if let group = fw.selectedGroup { MeshCoreBoardDetail(group: group) } else { choosePrompt }
                case .meshtastic:
                    if let board = fw.mtSelectedBoard, let release = fw.mtSelectedRelease { MeshtasticBoardDetail(board: board, release: release) } else { choosePrompt }
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await fw.load()
            if !fw.hasSelection, fw.query.isEmpty, let board = model.detectedBoard { fw.selectBoard(matching: board) }
        }
        .onChange(of: model.detectedBoard) { _, board in
            if !fw.hasSelection, fw.query.isEmpty, let board { fw.selectBoard(matching: board) }
        }
        .onChange(of: fw.role) { _, _ in
            guard fw.vendor == .meshcore else { return }
            fw.selectedBoardID = nil
            Task { await fw.load() }
        }
        .onChange(of: fw.sourceID) { _, _ in
            fw.selectedTag = nil; fw.selectedBoardID = nil
            Task { await fw.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in fw.reloadSources() }
        .onChange(of: fw.channel) { _, _ in
            guard fw.vendor == .meshtastic else { return }
            fw.mtSelectedVersion = nil; fw.mtSelectedSlug = nil
            Task { await fw.reloadMeshtasticBoards() }
        }
    }

    private var choosePrompt: some View {
        ContentUnavailableView("Choose a board", systemImage: "cpu",
                               description: Text("Pick a board on the left to see what it offers."))
    }
}

/// "Your board" at the top of the list: what is plugged in, and a way to jump to its firmware.
private struct DetectedBoardStrip: View {
    let name: String
    let connected: Bool
    let canShow: Bool
    let show: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu").foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(connected ? "Connected" : "Plugged in").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if canShow { Button("Show", action: show).accessibilityLabel("Show firmware for \(name)") } else { Text("Not in this list").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Controls

private struct MeshCoreControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var fw = model.firmware
        Picker("Role", selection: $fw.role) {
            ForEach(MeshCoreRole.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        HStack {
            if !fw.sources.isEmpty {
                Picker("Source", selection: $fw.sourceID) {
                    Text("MeshCore (official)").tag(String?.none)
                    Divider()
                    ForEach(fw.sources) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden().fixedSize()
            }
            Picker("Version", selection: $fw.selectedTag) {
                ForEach(fw.releases, id: \.tagName) { r in
                    Text(fw.source == nil ? (r.tagName.components(separatedBy: "-v").last.map { "v\($0)" } ?? r.tagName) : r.tagName).tag(Optional(r.tagName))
                }
            }
            .labelsHidden().frame(maxWidth: 220)
            Button { Task { await fw.refresh() } } label: { Label("Refresh release list", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                .help("Fetch the latest releases from GitHub")
            Spacer()
        }
    }
}

private struct MeshtasticControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var fw = model.firmware
        Picker("Channel", selection: $fw.channel) {
            ForEach(MeshtasticChannel.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        HStack {
            Picker("Version", selection: $fw.mtSelectedVersion) {
                ForEach(fw.mtChannelReleases) { r in Text("v\(r.version)").tag(Optional(r.version)) }
            }
            .labelsHidden().frame(maxWidth: 190)
            .onChange(of: fw.mtSelectedVersion) { _, _ in Task { await fw.reloadMeshtasticBoards() } }
            Button { Task { await fw.refresh() } } label: { Label("Refresh release list", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                .help("Fetch the latest releases from GitHub")
            Spacer()
        }
        Text(fw.channel.blurb).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Lists

private struct MeshCoreBoardList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var fw = model.firmware
        List(fw.boardGroups, selection: $fw.selectedBoardID) { group in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title).font(.body.weight(.medium))
                    Text(([group.maker] + [chipLabel(group)]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    ForEach(group.connections) { ConnectionBadge(connection: $0) }
                }
            }
            .padding(.vertical, 2)
            .tag(group.id)
        }
        .overlay { if fw.boardGroups.isEmpty && !fw.query.isEmpty { ContentUnavailableView.search(text: fw.query) } }
    }
}

private func chipLabel(_ group: FirmwareBoardGroup) -> String {
    group.isESP32 ? "ESP32" : group.isUF2 ? "nRF52" : ""
}

struct ConnectionBadge: View {
    let connection: MeshCoreConnection
    var body: some View {
        Label(connection.shortTitle, systemImage: connection.symbol)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help(connection.title)
    }
}

private struct MeshtasticBoardList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var fw = model.firmware
        VStack(spacing: 0) {
            let boards = fw.mtVisibleBoards
            List(selection: $fw.mtSelectedSlug) {
                ForEach(boards) { board in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(board.displayName).font(.body.weight(.medium))
                            Text([board.vendor, board.architectureLabel].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if board.supportLevel.map({ $0 > 1 }) ?? false { Pill(text: "Community") }
                    }
                    .padding(.vertical, 2)
                    .tag(board.slug)
                }
            }
            .overlay { if boards.isEmpty && !fw.query.isEmpty { ContentUnavailableView.search(text: fw.query) } }
            Divider()
            Toggle("Show community and unofficial boards", isOn: $fw.showCommunityBoards)
                .toggleStyle(.checkbox).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Details

/// Update or Clean install as one compact control with a single line saying what the choice does.
private struct InstallTypeControl: View {
    @Binding var isClean: Bool
    let updateNote: String
    let cleanNote: String
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Install type", systemImage: "arrow.triangle.2.circlepath").font(.headline)
            Picker("Install type", selection: $isClean) {
                Text("Update").tag(false)
                Text("Clean install").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            Label(isClean ? cleanNote : updateNote, systemImage: isClean ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout).foregroundStyle(isClean ? Color.red : .secondary)
            if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// USB, Bluetooth or Wi-Fi companion as one compact control with a line about the one chosen.
private struct ConnectionControl: View {
    let options: [MeshCoreConnection]
    @Binding var selection: MeshCoreConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connection", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
            Picker("Connection", selection: $selection) {
                ForEach(options) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(selection.blurb).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct OptionCard: View {
    let title: String
    let symbol: String
    let blurb: String
    let selected: Bool
    var destructive = false
    let action: () -> Void

    private var tint: Color { destructive ? .red : .accentColor }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title2).frame(width: 30).foregroundStyle(destructive ? Color.red : selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? tint : destructive ? Color.red.opacity(0.5) : .secondary.opacity(0.5)).accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? tint.opacity(0.12) : destructive ? Color.red.opacity(0.06) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? tint.opacity(0.7) : destructive ? Color.red.opacity(0.25) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MeshCoreBoardDetail: View {
    @Environment(AppModel.self) private var model
    let group: FirmwareBoardGroup

    var body: some View {
        let fw = model.firmware
        let connection = fw.effectiveConnection(for: group)
        let build = group.build(for: connection)
        let overSerial = installsOverSerial(build)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(group.title).font(.title2.weight(.semibold))
                        BoardMenu(artifacts: build?.artifacts ?? [], dfuBoardID: build?.isUF2 == true ? OTAFix.boardID(meshCoreSlug: group.board) : nil,
                                 serialDFU: build?.isUF2 == true ? fw.meshCoreSerialDFURequest(model: model) : nil,
                                 convert: convertAction(for: build),
                                 boardName: group.title)
                    }
                    Text(subtitle(build)).foregroundStyle(.secondary)
                }

                if group.connections.count > 1 {
                    ConnectionControl(options: group.connections,
                                      selection: Binding(get: { connection ?? .usb }, set: { fw.preferredConnection = $0 }))
                } else if let only = group.connections.first {
                    Label(only == .ble ? "Bluetooth only: there is no USB build for this board. MeshKit can install it but not configure it; use the MeshCore phone app." : "Only \(only.title) firmware exists for this board.", systemImage: only.symbol)
                        .font(.callout).foregroundStyle(.secondary)
                }

                if let build, build.isESP32 || build.isUF2 {
                    InstallTypeControl(isClean: Binding(get: { fw.mcMode == .fresh }, set: { fw.mcMode = $0 ? .fresh : .update }),
                                       updateNote: MeshCoreInstallMode.update.blurb, cleanNote: MeshCoreInstallMode.fresh.blurb,
                                       footnote: installFootnote(build, overSerial: overSerial))
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionBar(
                install: { install() }, canInstall: build?.fullImage != nil,
                convert: model.session == nil ? nil : convertAction(for: build),
                fileName: (overSerial ? build?.artifacts.first { $0.kind == .nrfDFUPackage } : build?.fullImage)?.asset.name,
                note: build?.fullImage == nil ? "No installable image is published for this board." : nil,
                installTint: .blue)
        }
    }

    /// A nRF52 board that is plugged in and running is installed over its serial port; the bootloader drive is the fallback.
    private func installsOverSerial(_ build: FirmwareBuild?) -> Bool {
        guard let build, build.isUF2, build.artifacts.contains(where: { $0.kind == .nrfDFUPackage }) else { return false }
        return model.uf2Volumes.isEmpty && !model.dfuCandidatePorts.isEmpty
    }

    private func convertAction(for build: FirmwareBuild?) -> ConvertChoice? {
        guard let build, build.isUF2 || build.isESP32, let slug = BoardPairs.meshtasticSlug(forMeshCoreBoard: group.board) else { return nil }
        return ConvertChoice(title: "Convert to Meshtastic…", options: [ConvertOption(label: "Convert to Meshtastic…") {
            FlashRequest.convertToMeshtastic(boardName: group.title, meshtasticSlug: slug, isESP32: build.isESP32, identity: $0)
        }])
    }

    private func install() {
        if let request = model.firmware.meshCoreInstallRequest(model: model) { model.pendingFlash = request }
    }

    private func subtitle(_ build: FirmwareBuild?) -> String {
        guard let build else { return "" }
        return "\(model.firmware.source?.name ?? "MeshCore") \(model.firmware.role.title) · v\(build.version)"
    }

    private func installFootnote(_ build: FirmwareBuild?, overSerial: Bool) -> String {
        guard let build else { return "" }
        if let source = model.firmware.source {
            return "Community build from \(source.repository). " + hardwareNote(build, overSerial: overSerial)
        }
        return hardwareNote(build, overSerial: overSerial)
    }

    private func hardwareNote(_ build: FirmwareBuild, overSerial: Bool) -> String {
        if overSerial { return "Installs over USB: no drive or reset button needed. If that fails you'll be offered the drive." }
        if build.isUF2 { return "Double-tap reset so the board's drive appears, then install." }
        if build.isESP32 {
            return "Update writes the app only. Clean install erases the chip and writes everything."
        }
        return ""
    }
}

private struct MeshtasticBoardDetail: View {
    @Environment(AppModel.self) private var model
    let board: MeshtasticBoard
    let release: MeshtasticRelease

    /// An update to an nRF52 board that is plugged in and running goes over its serial port; everything else needs the UF2 drive.
    private var installsOverSerial: Bool {
        board.isNRF52 && model.uf2Volumes.isEmpty && !model.dfuCandidatePorts.isEmpty
    }

    /// A board can become any of MeshCore's three roles; the choice is made when converting.
    private var meshCoreConvert: ConvertChoice? {
        BoardPairs.meshCoreSlug(forMeshtasticBoard: board.slug).map { slug in
            ConvertChoice(title: "Convert to MeshCore", options: [
                ConvertOption(label: "Companion (USB)…") { .convertToMeshCore(boardName: board.displayName, meshCoreSlug: slug, role: .companion, isESP32: board.isESP32, identity: $0) },
                ConvertOption(label: "Repeater…") { .convertToMeshCore(boardName: board.displayName, meshCoreSlug: slug, role: .repeater, isESP32: board.isESP32, identity: $0) },
                ConvertOption(label: "Room server…") { .convertToMeshCore(boardName: board.displayName, meshCoreSlug: slug, role: .roomServer, isESP32: board.isESP32, identity: $0) },
            ])
        }
    }

    var body: some View {
        @Bindable var fw = model.firmware
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(board.displayName).font(.title2.weight(.semibold))
                        BoardMenu(dfuBoardID: board.isNRF52 ? OTAFix.boardID(meshtasticSlug: board.slug) : nil,
                                 serialDFU: board.isNRF52 ? FlashRequest.meshtasticSerialDFU(board, release: release, clean: fw.mtMode == .fresh) : nil,
                                 convert: board.isNRF52 || board.isESP32 ? meshCoreConvert : nil,
                                 boardName: board.displayName)
                    }
                    HStack(spacing: 6) {
                        Text("Meshtastic v\(release.version)").foregroundStyle(.secondary)
                        Pill(text: release.channel.rawValue)
                        Pill(text: board.architectureLabel)
                        if board.supportLevel.map({ $0 > 1 }) ?? false { Pill(text: "Community") }
                        Link("Release notes", destination: release.pageURL).font(.callout)
                    }
                }

                InstallTypeControl(isClean: Binding(get: { fw.mtMode == .fresh }, set: { fw.mtMode = $0 ? .fresh : .update }),
                                   updateNote: MeshtasticInstallMode.update.blurb, cleanNote: MeshtasticInstallMode.fresh.blurb,
                                   footnote: board.isNRF52 ? (installsOverSerial ? "Installs over USB: no drive or reset button needed." : "Plug the board in and MeshKit installs over USB. Otherwise double-tap reset for its drive.") : nil)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionBar(
                install: { model.pendingFlash = fw.meshtasticInstallRequest(model: model) }, canInstall: true,
                convert: (board.isNRF52 || board.isESP32) && model.session != nil ? meshCoreConvert : nil,
                fileName: installsOverSerial ? fw.meshtasticFileName(board: board, release: release).replacingOccurrences(of: ".uf2", with: "-ota.zip") : fw.meshtasticFileName(board: board, release: release),
                note: nil, installTint: .green)
        }
    }
}

struct ConvertOption: Identifiable {
    let label: String
    let make: (NodeIdentity?) -> FlashRequest
    var id: String { label }
}

/// What a Convert button offers: one request, or a menu when the board can become several things.
struct ConvertChoice {
    let title: String
    let options: [ConvertOption]
}

/// The install button, any convert button and the exact file, kept at the bottom of the pane so they never scroll away
/// or get cut off.
private struct ActionBar: View {
    @Environment(AppModel.self) private var model
    let install: () -> Void
    let canInstall: Bool
    let convert: ConvertChoice?
    let fileName: String?
    let note: String?
    /// The colour of the firmware being installed.
    let installTint: Color

    private func convertLabel(_ title: String) -> some View {
        Label(title, systemImage: "arrow.left.arrow.right")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            if let fileName {
                Label { FileNameLabel(name: fileName) } icon: { Image(systemName: "doc").foregroundStyle(.secondary) }.font(.caption)
            }
            HStack {
                Button(action: install) { Label("Install", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent).tint(installTint).disabled(!canInstall)
                if let convert {
                    if let only = convert.options.first, convert.options.count == 1 {
                        Button { model.pendingFlash = only.make(model.currentIdentity) } label: { convertLabel(convert.title) }
                            .buttonStyle(.bordered)
                    } else {
                        Menu {
                            ForEach(convert.options) { option in
                                Button(option.label) { model.pendingFlash = option.make(model.currentIdentity) }
                            }
                        } label: { convertLabel(convert.title) }
                        .menuStyle(.button).buttonStyle(.bordered).menuIndicator(.visible).fixedSize()
                    }
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Extras for a board, kept out of the way: the release's files for people who want to flash them with another tool,
/// and the OTAFIX bootloader for nRF52 boards.
struct BoardMenu: View {
    @Environment(AppModel.self) private var model
    var artifacts: [FirmwareArtifact] = []
    var dfuBoardID: String?
    var serialDFU: FlashRequest?
    /// "Convert to Meshtastic…" and the request it opens, given the connected node's name and location (if any).
    var convert: ConvertChoice?
    var boardName: String

    var body: some View {
        if !artifacts.isEmpty || dfuBoardID != nil || serialDFU != nil || convert != nil { menu }
    }

    private var menu: some View {
        let fw = model.firmware
        return Menu {
            if !artifacts.isEmpty {
                Section("Firmware files") {
                    ForEach(artifacts) { artifact in
                        let size = ByteCountFormatter.string(fromByteCount: Int64(artifact.asset.size), countStyle: .file)
                        if fw.downloading.contains(artifact.id) {
                            Text("Downloading \(artifact.kind.rawValue)…")
                        } else if let url = fw.downloaded[artifact.id] {
                            Button("Show \(artifact.kind.rawValue) in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        } else {
                            Button("Download \(artifact.kind.rawValue) (\(size))") { Task { _ = await fw.download(artifact) } }
                        }
                    }
                }
            }
            if let serialDFU {
                Section("Install") {
                    Button("Install over USB (no drive needed)") { model.pendingFlash = serialDFU }
                }
            }
            if let convert {
                Section("Switch firmware") {
                    ForEach(convert.options) { option in
                        Button(convert.options.count == 1 ? option.label : "\(convert.title) as \(option.label.lowercased())") { model.pendingFlash = option.make(model.currentIdentity) }
                    }
                }
            }
            if let id = dfuBoardID {
                Section("Bluetooth DFU bootloader") {
                    Button("Install DFU bootloader fix") { model.pendingFlash = .dfuBootloaderFix(boardID: id, boardName: boardName) }
                    Button("Download DFU bootloader fix") {
                        Task {
                            await model.perform("Downloading the bootloader fix") {
                                let update = try await OTAFix.latestUpdate(for: id)
                                let url = try await OTAFix.download(update)
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                return "Downloaded \(update.asset.name)"
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").accessibilityLabel("More actions for \(boardName)")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Firmware files and bootloader")
    }
}

struct FileNameLabel: View {
    let name: String
    var body: some View {
        Text(name).font(.caption.monospaced()).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(name)
    }
}
