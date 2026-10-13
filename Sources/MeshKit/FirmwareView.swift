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
                    TextField("Filter boards", text: $fw.query).textFieldStyle(.roundedBorder)
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
        .task { await fw.load() }
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
                    Text("MeshCore").tag(String?.none)
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
            Button { Task { await fw.refresh() } } label: { Image(systemName: "arrow.clockwise") }
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
            Button { Task { await fw.refresh() } } label: { Image(systemName: "arrow.clockwise") }
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
    group.isESP32 ? "ESP32" : group.isUF2 ? "nRF52 · UF2" : ""
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
                        if board.isNRF52 { Pill(text: "UF2") }
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
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? tint : destructive ? Color.red.opacity(0.5) : .secondary.opacity(0.5))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(group.title).font(.title2.weight(.semibold))
                        BoardMenu(artifacts: build?.artifacts ?? [], dfuBoardID: build?.isUF2 == true ? OTAFix.boardID(meshCoreSlug: group.board) : nil,
                                 serialDFU: build?.isUF2 == true ? fw.meshCoreSerialDFURequest(model: model) : nil, boardName: group.title)
                    }
                    Text(subtitle(build)).foregroundStyle(.secondary)
                }

                if group.connections.count > 1 {
                    Card("Connection", symbol: "point.3.connected.trianglepath.dotted",
                         footnote: "MeshCore builds one companion firmware per connection type. They aren't interchangeable, so pick the one you'll use.") {
                        ForEach(group.connections) { c in
                            OptionCard(title: c.title, symbol: c.symbol, blurb: c.blurb, selected: c == connection) { fw.preferredConnection = c }
                        }
                    }
                } else if let only = group.connections.first {
                    Label("This board only has \(only.title) companion firmware. \(only.blurb)", systemImage: only.symbol)
                        .font(.callout).foregroundStyle(.secondary)
                }

                if let build, build.isESP32 || build.isUF2 {
                    Card("Install type", symbol: "arrow.triangle.2.circlepath") {
                        ForEach(MeshCoreInstallMode.allCases) { mode in
                            OptionCard(title: mode.rawValue, symbol: mode == .update ? "arrow.up.circle" : "sparkles", blurb: mode.blurb, selected: fw.mcMode == mode, destructive: mode == .fresh) { fw.mcMode = mode }
                        }
                    }
                }

                Card("Install", symbol: "bolt.fill", footnote: installFootnote(build)) {
                    HStack {
                        Button { if let r = fw.meshCoreRequest(model: model) { model.pendingFlash = r } } label: {
                            Label("Install", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(build?.fullImage == nil)
                        if let file = build?.fullImage?.asset.name { FileNameLabel(name: file) }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func subtitle(_ build: FirmwareBuild?) -> String {
        guard let build else { return "" }
        return "\(model.firmware.source?.name ?? "MeshCore") \(model.firmware.role.title) · v\(build.version)"
    }

    private func installFootnote(_ build: FirmwareBuild?) -> String {
        guard let build else { return "" }
        if let source = model.firmware.source {
            return "Community build from \(source.repository), not from the MeshCore project. " + hardwareNote(build)
        }
        return hardwareNote(build)
    }

    private func hardwareNote(_ build: FirmwareBuild) -> String {
        if build.isUF2 { return "Put the board in bootloader mode (double-tap reset) so its UF2 drive appears, then install. A clean install first runs Meshtastic's erase tool, so it needs a Meshtastic release to download it from." }
        if build.isESP32 {
            return "Only the full image is downloaded. An update writes just its boot-selection data and application; a clean install writes all of it at 0x0 after erasing the chip."
        }
        return ""
    }
}

private struct MeshtasticBoardDetail: View {
    @Environment(AppModel.self) private var model
    let board: MeshtasticBoard
    let release: MeshtasticRelease

    var body: some View {
        @Bindable var fw = model.firmware
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(board.displayName).font(.title2.weight(.semibold))
                        BoardMenu(dfuBoardID: board.isNRF52 ? OTAFix.boardID(meshtasticSlug: board.slug) : nil,
                                 serialDFU: board.isNRF52 ? FlashRequest.meshtasticSerialDFU(board, release: release) : nil, boardName: board.displayName)
                    }
                    HStack(spacing: 6) {
                        Text("Meshtastic v\(release.version)").foregroundStyle(.secondary)
                        Pill(text: release.channel.rawValue)
                        Pill(text: board.architectureLabel)
                        if board.supportLevel.map({ $0 > 1 }) ?? false { Pill(text: "Community") }
                        Link("Release notes", destination: release.pageURL).font(.callout)
                    }
                }

                Card("Install type", symbol: "arrow.triangle.2.circlepath",
                     footnote: board.isNRF52 ? "nRF52 boards install from a UF2 file: double-tap reset so the board's drive appears, then install." : nil) {
                    ForEach(MeshtasticInstallMode.allCases) { mode in
                        OptionCard(title: mode.rawValue, symbol: mode == .update ? "arrow.up.circle" : "sparkles", blurb: mode.blurb, selected: fw.mtMode == mode, destructive: mode == .fresh) { fw.mtMode = mode }
                    }
                }

                Card("Install", symbol: "bolt.fill", footnote: "Only this board's files are downloaded, not the whole multi-board package, and each is checked against the checksum published with the release.") {
                    HStack {
                        Button { if let r = fw.meshtasticRequest() { model.pendingFlash = r } } label: {
                            Label("Install", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        FileNameLabel(name: fw.meshtasticFileName(board: board, release: release))
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}

/// Extras for a board, kept out of the way: the release's files for people who want to flash them with another tool,
/// and the OTAFIX bootloader for nRF52 boards.
struct BoardMenu: View {
    @Environment(AppModel.self) private var model
    var artifacts: [FirmwareArtifact] = []
    var dfuBoardID: String?
    var serialDFU: FlashRequest?
    var boardName: String

    var body: some View {
        if !artifacts.isEmpty || dfuBoardID != nil || serialDFU != nil { menu }
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
                Section("nRF52 install") {
                    Button("Install over USB serial (no drive needed)") { model.pendingFlash = serialDFU }
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
            Image(systemName: "ellipsis.circle")
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
