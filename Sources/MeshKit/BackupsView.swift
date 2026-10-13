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
                Card("Settings backups", symbol: "externaldrive.badge.timemachine",
                     footnote: "Open Configure on a connected device and choose Back up settings.") {
                    if model.visibleSnapshots.isEmpty { EmptyRow(text: "No backups yet.") }
                    ForEach(model.visibleSnapshots) { snap in
                        Button { selection = selection == snap.id ? nil : snap.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snap.deviceName).font(.body.weight(.medium))
                                    Text("\(snap.kind == .companion ? "MeshCore companion" : snap.kind == .repeater ? "MeshCore repeater" : "Meshtastic") · \(snap.created.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == snap.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
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
        Card("nRF52 firmware", symbol: "memorychip",
             footnote: "The SoftDevice and application on an nRF52 board, saved from its bootloader drive before each UF2 install. They don't include the board's settings.") {
            if model.nrfBackups.isEmpty {
                EmptyRow(text: "None yet. They appear here after a UF2 install on an nRF52 board with the backup option on.")
            }
            ForEach(model.nrfBackups) { entry in
                HStack {
                    Image(systemName: "memorychip").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(entry.board) · \(entry.size >> 10) KB")
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore…") { model.pendingFlash = .restoreNRF52(entry) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Image(systemName: "magnifyingglass") }
                        .help("Show in Finder")
                    Button(role: .destructive) { try? FileManager.default.removeItem(at: entry.url); model.reloadFlashBackups() } label: { Image(systemName: "trash") }
                        .help("Delete")
                }
            }
        }
    }

    private var flashBackupCard: some View {
        Card("Flash images", symbol: "internaldrive",
             footnote: "Full copies of an ESP32 board's flash, saved automatically before each install. Restoring one puts the board back exactly as it was, including its settings and identity.") {
            if model.flashBackups.isEmpty {
                EmptyRow(text: "None yet. They appear here after you install firmware on an ESP32 board with the backup option on.")
            }
            ForEach(model.flashBackups) { entry in
                HStack {
                    Image(systemName: "memorychip").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(entry.chip) · \(entry.size >> 20) MB")
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore…") { model.pendingFlash = .restore(entry) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Image(systemName: "magnifyingglass") }
                        .help("Show in Finder")
                    Button(role: .destructive) { try? FileManager.default.removeItem(at: entry.url); model.reloadFlashBackups() } label: { Image(systemName: "trash") }
                        .help("Delete")
                }
            }
        }
    }
}

struct LogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logLines.isEmpty ? "Protocol traffic and events appear here." : model.logLines.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: model.logLines.count) { _, _ in proxy.scrollTo("end") }
            }
            Divider()
            HStack {
                Text("\(model.logLines.count) lines").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logLines.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { model.logLines = [] }
            }
            .padding(10)
        }
    }
}
