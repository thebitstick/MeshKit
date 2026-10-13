import MeshKitCore
import SwiftUI

struct FlashSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: FlashRequest

    @AppStorage("espBaud") private var baud = 460_800
    @AppStorage("espBackupFirst") private var backupFirst = true
    @State private var eraseFirst = false

    @State private var volumeID: String?
    @State private var portID: String?
    @State private var addressText = "0x0"
    @State private var steps: [FlashStep] = []
    @State private var running = false
    @State private var finished = false
    @State private var failure: String?
    @State private var confirming = false

    private var isUF2: Bool { request.target == .uf2 }
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
                if let warning = request.warning ?? (isUF2 ? nil : Self.defaultESPWarning) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                targetPicker
            } else {
                VStack(alignment: .leading, spacing: 10) { ForEach(steps) { StepRow(step: $0) } }
            }

            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            }
            if finished {
                Label("Done. The board should reboot into the new firmware.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button(finished ? "Close" : "Cancel") { dismiss() }.disabled(running).keyboardShortcut(.cancelAction)
                if !finished {
                    Button("Install") { confirming = true }
                        .buttonStyle(.borderedProminent).disabled(!canStart).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { eraseFirst = request.eraseDefault }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Install", role: .destructive) { Task { await start() } }
        } message: {
            Text(isUF2 ? "The image is copied to the bootloader drive and the board reboots into it."
                       : "The board's flash is rewritten. Don't unplug it until this finishes.")
        }
    }

    private static let defaultESPWarning = "This rewrites the board's flash. A backup of the current flash is saved first unless you turn that off."

    private var confirmTitle: String { "Install \(request.title.replacingOccurrences(of: "Install ", with: "")) on \((isUF2 ? volume?.name : port?.displayName) ?? "the board")?" }

    @ViewBuilder private var targetPicker: some View {
        if isUF2 {
            Picker("Bootloader drive", selection: $volumeID) {
                if model.uf2Volumes.isEmpty { Text("None found").tag(String?.none) }
                ForEach(model.uf2Volumes) { Text("\($0.name) — \($0.model)").tag(Optional($0.id)) }
            }
            if model.uf2Volumes.isEmpty {
                Text("Double-tap the reset button so the board's drive mounts. This list updates automatically.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Picker("Serial port", selection: $portID) {
                if model.ports.isEmpty { Text("None found").tag(String?.none) }
                ForEach(model.ports) { Text("\($0.displayName) — \($0.hint)").tag(Optional($0.id)) }
            }
            if request.needsAddress {
                LabeledContent("Write at address") { TextField("0x0", text: $addressText).textFieldStyle(.roundedBorder).frame(width: 120).font(.body.monospaced()) }
            }
            if request.offersErase {
                Toggle("Erase the whole flash first", isOn: $eraseFirst)
                Text(eraseFirst ? "Settings and data on the board are lost. Recommended for a first install."
                                : "Only the image's own area is rewritten, so settings stored elsewhere on the board are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Back up the current flash first", isOn: $backupFirst)
            Picker("Speed", selection: $baud) {
                Text("115,200 (slowest, most compatible)").tag(115_200)
                Text("460,800").tag(460_800)
                Text("921,600 (fastest)").tag(921_600)
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
            guard let volume else { failure = "No bootloader drive is mounted."; return }
            flasher = UF2VolumeFlasher(volume: volume, image: data, erase: erase)
        case .esp(var job):
            guard let port else { failure = "No serial port is selected."; return }
            if request.offersErase { job.eraseAll = eraseFirst }
            // Free the port if a device session is using it.
            if model.session?.portName == port.displayName { model.disconnect(); try? await Task.sleep(for: .milliseconds(300)) }
            let log: @Sendable (String) -> Void = { line in Task { @MainActor in model.log("esp: \(line)") } }
            flasher = ESPFlasher(portPath: port.path, job: job, options: ESPFlashOptions(baudRate: baud, backupFirst: backupFirst), logger: log)
        }
        steps += flasher.steps

        let (stream, continuation) = AsyncStream.makeStream(of: (String, FlashStep.State).self)
        let consumer = Task { @MainActor in for await (id, state) in stream { set(id, state) } }
        do {
            try await flasher.run { continuation.yield(($0, $1)) }
            continuation.finish(); await consumer.value
            finished = !steps.contains { if case .failed = $0.state { true } else { false } }
            if !finished { failure = "The board did not reboot as expected." }
            model.log("Flash finished: \(request.title)")
        } catch {
            continuation.finish(); await consumer.value
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
