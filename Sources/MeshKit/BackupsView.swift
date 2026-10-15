import MeshKitCore
import SwiftUI

struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var message: String?
    @State private var restoring = false
    @State private var confirmRestore = false

    private var selected: ConfigSnapshot? { model.visibleSnapshots.first { $0.id == selection } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Card("Settings backups", symbol: "externaldrive.badge.timemachine") {
                    HStack {
                        Button("Back up…") { Task { await model.backUpConnectedDevice() } }.disabled(model.canSendCommands != true)
                        if model.canSendCommands != true { Text("Connect a device to back up its settings.").font(.caption).foregroundStyle(.secondary) }
                    }
                    if model.visibleSnapshots.isEmpty { EmptyRow(text: "No settings backups yet.") }
                    ForEach(model.visibleSnapshots) { snap in
                        Button { selection = selection == snap.id ? nil : snap.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snap.deviceName).font(.body.weight(.medium))
                                    Text("\(snap.kind == .companion ? "MeshCore companion" : snap.kind == .repeater ? "MeshCore repeater" : "Meshtastic") · \(snap.created.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == snap.id { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Selected") }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let snap = selected { detail(snap) }
                flashBackupCard
                nrfBackupCard
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.reloadSnapshots(); model.reloadFlashBackups() }
    }

    @ViewBuilder private func detail(_ snap: ConfigSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snap.deviceName).font(.title2.weight(.semibold))
            Text([snap.board, snap.firmware].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
        }

        Card("Settings", symbol: "list.bullet.rectangle", footnote: "Private keys and passwords are never included in backups.") {
            ForEach(snap.values.sorted { $0.key < $1.key }, id: \.key) { key, value in
                HStack(alignment: .firstTextBaseline) {
                    Text(CLICatalog.setting(key)?.label ?? key).foregroundStyle(.secondary)
                    Spacer()
                    Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                }
            }
        }

        HStack {
            Button("Restore to connected device…") { confirmRestore = true }
                .buttonStyle(.borderedProminent)
                .disabled(restoreDisabledReason != nil || restoring)
            if let reason = restoreDisabledReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([SnapshotStore.directory.appendingPathComponent("\(snap.id.uuidString).json")])
            }
            Button("Delete", role: .destructive) { SnapshotStore.delete(snap); selection = nil; model.reloadSnapshots() }
        }
        if let message { Text(message).font(.callout).foregroundStyle(.secondary) }

        Color.clear.frame(height: 0)
            .confirmationDialog("Restore \(snap.values.count) settings to \(model.session?.title ?? "device")?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Restore") { Task { await restore(snap) } }
            } message: {
                Text("This overwrites the device's current values. Radio changes need a reboot.")
            }
    }

    private var restoreDisabledReason: String? {
        guard let session = model.session else { return "Connect a device first" }
        guard let snap = selected else { return nil }
        let sameKind: Bool = switch (snap.kind, session.kind) {
        case (.companion, .companion), (.repeater, .repeater), (.meshtastic, .meshtastic): true
        default: false
        }
        let matches = sameKind
        return matches ? nil : "Connected device is a different kind"
    }

    private func restore(_ snap: ConfigSnapshot) async {
        guard let session = model.session else { return }
        restoring = true; defer { restoring = false }
        do { message = "Restored \(try await model.restore(snap, to: session)) settings." } catch { message = error.localizedDescription }
    }

    private var nrfBackupCard: some View {
        Card("nRF52 firmware images", symbol: "memorychip",
             footnote: "What the board was running, without its settings.") {
            if model.nrfBackups.isEmpty { EmptyRow(text: "No firmware images yet.") }
            HStack {
                if model.uf2Volumes.count > 1 {
                    Menu("Back up…") {
                        ForEach(model.uf2Volumes) { volume in Button(volume.name) { Task { await model.backUpFirmware(on: volume) } } }
                    }
                    .fixedSize()
                } else {
                    Button("Back up…") { if let volume = model.uf2Volumes.first { Task { await model.backUpFirmware(on: volume) } } }
                        .disabled(model.uf2Volumes.isEmpty)
                }
                if model.uf2Volumes.isEmpty {
                    Text("Double-tap reset so the board's drive appears.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(model.nrfBackups) { entry in
                HStack {
                    Image(systemName: "memorychip").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.firmware ?? "\(entry.board) firmware")
                        Text("\(entry.board) · \(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.size >> 10) KB").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore…") { model.pendingFlash = model.uf2Volumes.isEmpty && !model.dfuCandidatePorts.isEmpty ? .restoreNRF52OverSerial(entry) : .restoreNRF52(entry) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Label("Show in Finder", systemImage: "magnifyingglass").labelStyle(.iconOnly) }
                        .help("Show in Finder")
                    Button(role: .destructive) { try? FileManager.default.removeItem(at: entry.url); model.reloadFlashBackups() } label: { Label("Delete this backup", systemImage: "trash").labelStyle(.iconOnly) }
                        .help("Delete")
                }
            }
        }
    }

    private var flashBackupCard: some View {
        Card("ESP32 flash images", symbol: "internaldrive",
             footnote: "Full copies, including settings and identity.") {
            if model.flashBackups.isEmpty { EmptyRow(text: "No flash images yet.") }
            HStack {
                Button("Back up…") { model.pendingFlash = .espBackup }.disabled(model.ports.isEmpty)
                if model.ports.isEmpty { Text("Connect an ESP32 board over USB.").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(model.flashBackups) { entry in
                HStack {
                    Image(systemName: "memorychip").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.firmware ?? "\(entry.chip) flash image")
                        Text("\(entry.chip) · \(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.size >> 20) MB").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore…") { model.pendingFlash = .restore(entry) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Label("Show in Finder", systemImage: "magnifyingglass").labelStyle(.iconOnly) }
                        .help("Show in Finder")
                    Button(role: .destructive) { try? FileManager.default.removeItem(at: entry.url); model.reloadFlashBackups() } label: { Label("Delete this backup", systemImage: "trash").labelStyle(.iconOnly) }
                        .help("Delete")
                }
            }
        }
    }
}

struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    private var shown: [String] {
        filter.isEmpty ? model.logLines : model.logLines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func isProblem(_ line: String) -> Bool {
        ["failed", "error", "refused", "no answer", "timed out"].contains { line.localizedCaseInsensitiveContains($0) }
    }

    /// What to paste into a bug report: the app and macOS versions, then the log.
    private var report: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return "MeshKit \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n" + model.logLines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.logLines.isEmpty {
                        Text("Nothing yet. Connect a device or run an install.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption.monospaced()).textSelection(.enabled)
                                    .foregroundStyle(isProblem(line) ? Color.red : .primary)
                                    .accessibilityLabel(isProblem(line) ? "Problem: \(line)" : line)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: model.logLines.count) { _, _ in proxy.scrollTo("end") }
            }
            Divider()
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180).accessibilityLabel("Filter log lines")
                Text(filter.isEmpty ? "\(model.logLines.count) lines" : "\(shown.count) of \(model.logLines.count) lines").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save…") { save() }.disabled(model.logLines.isEmpty)
                Button("Copy for Bug Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .disabled(model.logLines.isEmpty)
                Button("Clear") { model.logLines = [] }
            }
            .padding(10)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MeshKit log.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url { try? report.write(to: url, atomically: true, encoding: .utf8) }
    }
}
