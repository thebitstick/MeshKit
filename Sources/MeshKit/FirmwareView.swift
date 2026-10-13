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
            Picker("Version", selection: $fw.selectedTag) {
                ForEach(fw.releases, id: \.tagName) { r in
                    Text(r.tagName.components(separatedBy: "-v").last.map { "v\($0)" } ?? r.tagName).tag(Optional(r.tagName))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title2).frame(width: 30).foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
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
                    Text(group.title).font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(subtitle(build)).foregroundStyle(.secondary)
                    }
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

                if let build {
                    Card("Images", symbol: "doc.zipper") {
                        ForEach(build.artifacts) { ArtifactRow(artifact: $0) }
                    }
                }

                Card("Install", symbol: "bolt.fill", footnote: installFootnote(build)) {
                    Button { if let r = fw.meshCoreRequest(model: model) { model.pendingFlash = r } } label: {
                        Label("Install \(fw.role.title)\(connection.map { " · \($0.title)" } ?? "")…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(build?.fullImage == nil)
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func subtitle(_ build: FirmwareBuild?) -> String {
        guard let build else { return "" }
        return "MeshCore \(model.firmware.role.title) · v\(build.version)"
    }

    private func installFootnote(_ build: FirmwareBuild?) -> String {
        guard let build else { return "" }
        if build.isUF2 { return "Put the board in bootloader mode (double-tap reset) so its UF2 drive appears, then install." }
        if build.isESP32 {
            return "Full images include bootloader, partitions and app, and are written at 0x0. App-only images are for updates that keep settings."
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
                    Text(board.displayName).font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Text("Meshtastic v\(release.version)").foregroundStyle(.secondary)
                        Pill(text: release.channel.rawValue)
                        Pill(text: board.architectureLabel)
                        if board.supportLevel.map({ $0 > 1 }) ?? false { Pill(text: "Community") }
                    }
                }

                if board.isESP32 {
                    Card("Install type", symbol: "arrow.triangle.2.circlepath") {
                        ForEach(MeshtasticInstallMode.allCases) { mode in
                            OptionCard(title: mode.rawValue, symbol: mode == .update ? "arrow.up.circle" : "sparkles", blurb: mode.blurb, selected: fw.mtMode == mode) { fw.mtMode = mode }
                        }
                    }
                } else {
                    Label("nRF52 boards install from a UF2 file. Double-tap reset so the board's drive appears, then install. Settings are kept.",
                          systemImage: "externaldrive")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Card("Install", symbol: "bolt.fill", footnote: "Only this board's files are downloaded, not the whole multi-board package, and each is checked against the checksum published with the release.") {
                    HStack {
                        Button { if let r = fw.meshtasticRequest() { model.pendingFlash = r } } label: {
                            Label("Install Meshtastic…", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        Link("Release notes", destination: release.pageURL)
                        Spacer()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}

struct ArtifactRow: View {
    @Environment(AppModel.self) private var model
    let artifact: FirmwareArtifact

    var body: some View {
        let fw = model.firmware
        HStack {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.kind.rawValue)
                Text(artifact.asset.name).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(artifact.asset.size), countStyle: .file))
                .font(.caption).foregroundStyle(.secondary)
            if fw.downloading.contains(artifact.id) {
                ProgressView().controlSize(.small)
            } else if let url = fw.downloaded[artifact.id] {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } else {
                Button("Download") { Task { _ = await fw.download(artifact) } }
            }
        }
    }

    private var symbol: String {
        switch artifact.kind {
        case .espFullImage: "memorychip.fill"
        case .espAppImage: "memorychip"
        case .uf2: "externaldrive"
        case .nrfDFUPackage: "shippingbox"
        case .other: "doc"
        }
    }
}
