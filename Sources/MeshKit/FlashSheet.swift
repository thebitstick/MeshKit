import MeshKitCore
import SwiftUI

struct FlashSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: FlashRequest

    @AppStorage("espBaud") private var baud = 460_800
    /// The Settings value is only where each install starts; changing the box here applies to this install alone.
    @AppStorage("espBackupFirst") private var backupDefault = true
    @AppStorage("nrfBackupFirst") private var nrfBackupDefault = true
    @State private var backupFirst = true
    @State private var nrfBackupFirst = true
    @State private var eraseFirst = false
    @State private var showDetails = false
    @State private var connecting = false

    @State private var volumeID: String?
    @State private var portID: String?
    @State private var addressText = "0x0"
    @State private var steps: [FlashStep] = []
    @State private var running = false
    @State private var finished = false
    @State private var failure: String?
    @State private var confirming = false

    private var isUF2: Bool { request.target == .uf2 }
    private var isESP: Bool { request.target == .esp }
    private var volume: UF2Volume? { model.uf2Volumes.first { $0.id == volumeID } ?? (model.uf2Volumes.count == 1 ? model.uf2Volumes[0] : nil) }
    private var port: SerialPortInfo? { model.ports.first { $0.id == portID } ?? (model.ports.count == 1 ? model.ports[0] : nil) }
    private var address: UInt32? {
        var t = addressText.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2); return UInt32(t, radix: 16) }
        return UInt32(t)
    }
    private var canStart: Bool {
        !running && !finished && (isUF2 ? volume != nil : port != nil) && (!request.needsAddress || address != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).font(.title3.weight(.semibold))
                Text(request.subtitle).foregroundStyle(.secondary)
            }

            if steps.isEmpty {
                NotesView(notes: request.notes.isEmpty && isESP ? [.caution("Rewrites the board's flash.")] : request.notes)
                targetPicker
            } else {
                VStack(alignment: .leading, spacing: 10) { ForEach(steps) { StepRow(step: $0) } }
            }

            if let failure {
                VStack(alignment: .leading, spacing: 6) {
                    Label(summary(of: failure), systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout.weight(.medium))
                    if failure != summary(of: failure) {
                        if showDetails { Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Button(showDetails ? "Hide details" : "Show details") { showDetails.toggle() }.buttonStyle(.link).font(.caption)
                    }
                    if let fallback = request.fallback {
                        Button("Use the board's drive instead") { if let next = fallback() { model.pendingFlash = next } }
                            .help("Double-tap the board's reset button so its drive appears, then install from there")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if finished, failure == nil {
                Label(isBackup ? "Done. The backup is in the Backups tab." : "Done. The board has restarted into the new firmware.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            HStack {
                if finished, !isBackup {
                    Button("Connect to the board") { Task { await connectAfterInstall() } }.disabled(connecting)
                }
                Spacer()
                Button(finished ? "Close" : "Cancel") { dismiss() }.disabled(running).keyboardShortcut(.cancelAction)
                if !finished {
                    Button(actionTitle) { confirming = true }
                        .buttonStyle(.borderedProminent).disabled(!canStart).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { eraseFirst = request.eraseDefault; backupFirst = backupDefault; nrfBackupFirst = nrfBackupDefault }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(actionTitle, role: isBackup ? nil : .destructive) { Task { await start() } }
        } message: {
            Text(isBackup ? "The flash is read over USB and saved. Nothing on the board changes."
                       : isUF2 ? "The image is copied to the board's drive and the board restarts into it."
                       : isESP ? "The board's flash is rewritten. Don't unplug it until this finishes."
                       : "The board restarts in update mode and the firmware is sent over USB. Don't unplug it until this finishes.")
        }
    }

    private func uf2Backup(for volume: UF2Volume) -> (@Sendable (Data) throws -> Void)? {
        guard nrfBackupFirst, request.allowsBackup else { return nil }
        let board = volume.model.isEmpty ? volume.boardID : volume.model
        return { image in try NRF52BackupStore.save(image, board: board) }
    }

    /// The first sentence of a long error, so the sheet shows what happened and keeps the rest one click away.
    private func summary(of message: String) -> String {
        guard let end = message.range(of: ". ") else { return message }
        return String(message[..<end.lowerBound]) + "."
    }

    /// A restarted board takes a few seconds to show up again; connect to it when exactly one board is there.
    private func connectAfterInstall() async {
        connecting = true
        defer { connecting = false }
        for _ in 0..<12 {
            model.refreshDevices()
            try? await Task.sleep(for: .seconds(1.5))
            if model.ports.count == 1, let only = model.ports.first {
                dismiss()
                model.section = .configure
                await model.connect(port: only)
                return
            }
        }
        dismiss()
        model.show(AppModel.Notice(text: "Couldn't find the board again. Pick it from the device menu.", isError: true))
    }

    private var isBackup: Bool { request.title == FlashRequest.espBackup.title }
    private var actionTitle: String { isBackup ? "Back Up" : request.title.hasPrefix("Restore") ? "Restore" : request.title.hasPrefix("Convert") ? "Convert" : "Install" }
    private var confirmTitle: String {
        let target = (isUF2 ? volume?.name : port?.displayName) ?? "the board"
        if isBackup { return "Back up the flash of \(target)?" }
        let subject = request.title.replacingOccurrences(of: "Install ", with: "").replacingOccurrences(of: "Restore ", with: "").replacingOccurrences(of: "Convert ", with: "")
        return request.title.hasPrefix("Convert") ? "Convert \(subject) on \(target)?" : "\(actionTitle) \(subject) on \(target)?"
    }

    @ViewBuilder private var targetPicker: some View {
        if isUF2 {
            Picker("Board's drive", selection: Binding(get: { volume?.id }, set: { volumeID = $0 })) {
                if model.uf2Volumes.isEmpty { Text("None found").tag(String?.none) }
                ForEach(model.uf2Volumes) { Text("\($0.name) — \($0.model)").tag(Optional($0.id)) }
            }
            .accessibilityLabel("Board's drive")
            if model.uf2Volumes.isEmpty {
                Text("Double-tap the reset button so the board's drive mounts. This list updates automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                if !model.dfuCandidatePorts.isEmpty {
                    Button("Restart in update mode") { Task { await model.enterDFUModeOnLikelyPort(wantsDrive: true) } }
                    if let notice = model.notice {
                        Text(notice.text).font(.callout).foregroundStyle(notice.isError ? .red : .secondary)
                    }
                }
            } else {
                if let volume, let note = request.volumeNote?(volume) {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                if request.allowsBackup {
                    Toggle("Back up the current firmware first", isOn: $nrfBackupFirst)
                }
            }
        } else {
            Picker("Serial port", selection: Binding(get: { port?.id }, set: { portID = $0 })) {
                if model.ports.isEmpty { Text("None found").tag(String?.none) }
                ForEach(model.ports) { Text("\($0.displayName) — \($0.hint)").tag(Optional($0.id)) }
            }
            .accessibilityLabel("Serial port")
            if isESP, request.needsAddress {
                LabeledContent("Write at address") { TextField("0x0", text: $addressText).textFieldStyle(.roundedBorder).frame(width: 120).font(.body.monospaced()) }
            }
            if isESP, request.offersErase {
                Toggle("Erase the whole flash first", isOn: $eraseFirst)
                Text(eraseFirst ? "Settings and data on the board are lost. Recommended for a first install."
                                : "Only the image's own area is rewritten, so settings stored elsewhere on the board are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isESP, request.title != FlashRequest.espBackup.title {
                Toggle("Back up the current flash first", isOn: $backupFirst)
                Picker("Speed", selection: $baud) {
                    Text("115,200 (slowest, most compatible)").tag(115_200)
                    Text("460,800").tag(460_800)
                    Text("921,600 (fastest)").tag(921_600)
                }
                .accessibilityLabel("Flash speed")
            }
        }
        if !request.details.isEmpty {
            Text(request.details.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func start() async {
        running = true; failure = nil
        defer { running = false }
        func set(_ id: String, _ state: FlashStep.State) {
            if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].state = state }
        }

        steps = [FlashStep(id: "prepare", title: request.prepareTitle)]
        set("prepare", .running(nil))
        let payload: FlashPayload
        do { payload = try await request.prepare(FlashContext(address: address ?? 0)) } catch {
            set("prepare", .failed(error.localizedDescription)); failure = error.localizedDescription; return
        }
        set("prepare", .done)

        let flasher: Flasher
        switch payload {
        case .uf2(let data, let erase):
            guard let volume else { failure = "The board's drive isn't showing."; return }
            flasher = UF2VolumeFlasher(volume: volume, image: data, erase: erase, onBackup: uf2Backup(for: volume))
        case .bootloaderUpdate(let data):
            guard let volume else { failure = "The board's drive isn't showing."; return }
            flasher = UF2VolumeFlasher(volume: volume, image: data, content: .bootloaderUpdate, onBackup: uf2Backup(for: volume))
        case .uf2Restore(let data):
            guard let volume else { failure = "The board's drive isn't showing."; return }
            flasher = UF2VolumeFlasher(volume: volume, image: data, content: .restore)
        case .nrfSerialDFU(let package):
            guard let port else { failure = "No serial port is selected."; return }
            if model.session?.portName == port.displayName { model.disconnect(); try? await Task.sleep(for: .milliseconds(300)) }
            let log: @Sendable (String) -> Void = { line in Task { @MainActor in model.log("dfu: \(line)") } }
            flasher = NRF52SerialDFUFlasher(portPath: port.path, package: package, logger: log)
        case .nrfSerialClean(let eraser, let package):
            guard let port else { failure = "No serial port is selected."; return }
            if model.session?.portName == port.displayName { model.disconnect(); try? await Task.sleep(for: .milliseconds(300)) }
            let log: @Sendable (String) -> Void = { line in Task { @MainActor in model.log("dfu: \(line)") } }
            flasher = NRF52SerialCleanFlasher(portPath: port.path, eraser: eraser, package: package, logger: log)
        case .esp(var job):
            guard let port else { failure = "No serial port is selected."; return }
            if request.offersErase { job.eraseAll = eraseFirst }
            // Free the port if a device session is using it.
            if model.session?.portName == port.displayName { model.disconnect(); try? await Task.sleep(for: .milliseconds(300)) }
            let log: @Sendable (String) -> Void = { line in Task { @MainActor in model.log("esp: \(line)") } }
            flasher = ESPFlasher(portPath: port.path, job: job, options: ESPFlashOptions(baudRate: baud, backupFirst: backupFirst || job.images.isEmpty), logger: log)
        }
        steps += flasher.steps

        let (stream, continuation) = AsyncStream.makeStream(of: (String, FlashStep.State).self)
        let consumer = Task { @MainActor in for await (id, state) in stream { set(id, state) } }
        do {
            try await flasher.run { continuation.yield(($0, $1)) }
            continuation.finish(); await consumer.value
            let installed = !steps.contains { if case .failed = $0.state { true } else { false } }
            if !installed { failure = "The board did not reboot as expected." }
            // "Done" waits for the follow-up step: it can take a minute, and the person must not quit before it ends.
            if installed, let after = request.afterFlash {
                steps.append(FlashStep(id: "after", title: after.title))
                set("after", .running(nil))
                let log: @Sendable (String) -> Void = { line in Task { @MainActor in model.log(line) } }
                do { try await after.run(port?.path, log); set("after", .done) } catch {
                    set("after", .failed(error.localizedDescription))
                    failure = "The firmware is installed, but: \(error.localizedDescription)"
                }
            }
            finished = installed
            model.log("Flash finished: \(request.title)")
        } catch {
            continuation.finish(); await consumer.value
            // Whatever step was in progress is the one that failed; leaving its spinner running looks like a hang.
            for index in steps.indices { if case .running = steps[index].state { steps[index].state = .failed(error.localizedDescription) } }
            failure = error.localizedDescription
            model.log("Flash failed: \(error.localizedDescription)")
        }
        model.reloadFlashBackups()
    }
}

struct StepRow: View {
    let step: FlashStep

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).foregroundStyle(step.state == .pending ? .secondary : .primary)
                if case .running(let p?) = step.state { ProgressView(value: p).frame(maxWidth: 260) }
                if case .failed(let msg) = step.state { Text(msg).font(.caption).foregroundStyle(.red) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.title)
        .accessibilityValue(spoken)
    }

    /// What the icon says, in words, so state isn't carried by a symbol and its colour alone.
    private var spoken: String {
        switch step.state {
        case .pending: "waiting"
        case .running(let p): p.map { "in progress, \(Int($0 * 100)) percent" } ?? "in progress"
        case .done: "done"
        case .failed(let message): "failed: \(message)"
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}


/// Dangers in a tinted box on top, then what is kept and how it works as plain rows.
private struct NotesView: View {
    let notes: [FlashNote]

    private var alerts: [FlashNote] { notes.filter { $0.kind == .danger || $0.kind == .caution } }
    private var rest: [FlashNote] { notes.filter { $0.kind == .keep || $0.kind == .info } }
    private var tint: Color { alerts.contains { $0.kind == .danger } ? .red : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !alerts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(alerts) { note in
                        Label(note.text, systemImage: note.kind == .danger ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                            .font(.callout.weight(.medium)).foregroundStyle(note.kind == .danger ? Color.red : Color.orange)
                            .accessibilityLabel("\(note.kind == .danger ? "Warning" : "Caution"): \(note.text)")
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(rest) { note in
                Label {
                    Text(note.text).font(note.kind == .keep ? .callout : .caption).foregroundStyle(note.kind == .keep ? .primary : .secondary)
                } icon: {
                    Image(systemName: note.kind == .keep ? "checkmark.circle.fill" : "info.circle").foregroundStyle(note.kind == .keep ? Color.green : .secondary)
                }
                .accessibilityLabel(note.kind == .keep ? "Kept: \(note.text)" : note.text)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
