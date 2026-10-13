import MeshKitCore
import SwiftUI

struct ConfigureView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.session {
            switch session.kind {
            case .companion: CompanionConfigView(session: session).id(session.id)
            case .repeater: RepeaterConfigView(session: session).id(session.id)
            case .meshtastic: MeshtasticConfigView(session: session).id(session.id)
            }
        } else {
            ContentUnavailableView {
                Label("No device connected", systemImage: "cable.connector.slash")
            } description: {
                Text(model.vendor == .meshcore ? "Connect a MeshCore companion, repeater or room server to read and change its settings." : "Connect a Meshtastic node to read and change its settings.")
            } actions: {
                Button("Choose a Device") { model.showingDevices = true }
            }
        }
    }
}

// MARK: - Companion

struct CompanionConfigView: View {
    @Environment(AppModel.self) private var model
    let session: DeviceSession

    struct Draft: Equatable {
        var name = "", lat = "", lon = "", freq = "", bw = ""
        var sf = 7, cr = 5, tx = 14
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var busy = false
    @State private var message: Message?
    @State private var contacts: [Contact] = []
    @State private var status: [String] = []

    struct Message: Equatable { let text: String; let isError: Bool }

    var body: some View {
        Form {
            if let info = session.deviceInfo, let me = session.selfInfo {
                Section("Device") {
                    LabeledContent("Model", value: info.model)
                    LabeledContent("Firmware", value: "\(info.semanticVersion) (\(info.buildDate))")
                    LabeledContent("Capacity", value: "\(info.maxContacts) contacts · \(info.maxChannels) channels")
                    LabeledContent("Public key") { Text(me.publicKeyHex).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }

            Section("Identity") {
                TextField("Node name", text: $draft.name)
                TextField("Latitude", text: $draft.lat)
                TextField("Longitude", text: $draft.lon)
            }

            Section {
                LabeledContent {
                    RadioPresetMenu(current: draftRadio) { applyPreset($0) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Radio preset")
                        PresetMatchNote(values: draftRadio)
                    }
                }
                TextField("Frequency (MHz)", text: $draft.freq)
                TextField("Bandwidth (kHz)", text: $draft.bw)
                Stepper("Spreading factor: \(draft.sf)", value: $draft.sf, in: 5...12)
                Stepper("Coding rate: 4/\(draft.cr)", value: $draft.cr, in: 5...8)
                Stepper("TX power: \(draft.tx) dBm", value: $draft.tx, in: 1...(session.selfInfo?.maxTxPowerDBm ?? 22))
            } header: {
                Text("Radio")
            } footer: {
                Text("All nodes on a network must share frequency, bandwidth, spreading factor and coding rate.")
            }

            Section("Actions") {
                HStack {
                    Button("Send advert") { run("Advert sent") { try await $0.sendAdvert(flood: true) } }
                    Button("Sync clock") { run("Clock synced") { try await $0.syncClock() } }
                    Button("Refresh status") { Task { await refreshStatus() } }
                    Button("Reboot", role: .destructive) { run("Reboot requested") { try await $0.reboot() } }
                    Spacer()
                }
                if !status.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(status, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                }
            }

            Section("Contacts") {
                HStack {
                    Button(contacts.isEmpty ? "Load contacts" : "Reload") { Task { await loadContacts() } }
                    if !contacts.isEmpty { Text("\(contacts.count) contacts").foregroundStyle(.secondary) }
                }
                if !contacts.isEmpty {
                    Table(contacts) {
                        TableColumn("Name", value: \.name)
                        TableColumn("Type") { Text($0.type.label) }.width(90)
                        TableColumn("Hops") { Text($0.outPathLength < 0 ? "flood" : "\($0.outPathLength)") }.width(60)
                        TableColumn("Last heard") { Text($0.lastAdvert, format: .relative(presentation: .named)) }.width(110)
                    }
                    .frame(height: min(CGFloat(contacts.count) * 28 + 40, 260))
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        .onAppear(perform: loadDraft)
        .onChange(of: model.settingsRefreshRequest) { _, _ in Task { await refreshFromDevice() } }
        .onChange(of: model.pendingPreset) { _, pending in
            guard let pending else { return }
            applyPreset(pending.preset); model.pendingPreset = nil
        }
    }

    private func refreshFromDevice() async {
        guard let c = session.companion else { return }
        busy = true; defer { busy = false }
        do {
            let (info, me) = try await c.handshake()
            session.deviceInfo = info; session.selfInfo = me
            loadDraft()
            message = .init(text: "Read settings from the device", isError: false)
        } catch { message = .init(text: error.localizedDescription, isError: true) }
    }

    private var draftRadio: RadioValues? { RadioValues(frequency: draft.freq, bandwidth: draft.bw, sf: draft.sf, cr: draft.cr) }

    private func applyPreset(_ p: RadioPreset) {
        draft.freq = String(p.frequencyMHz); draft.bw = String(p.bandwidthKHz); draft.sf = p.spreadingFactor; draft.cr = p.codingRate
        message = .init(text: "\(p.title) preset staged. Apply to write it to the device.", isError: false)
    }

    private var changeCount: Int {
        var n = 0
        if draft.name != original.name { n += 1 }
        if draft.lat != original.lat || draft.lon != original.lon { n += 1 }
        if (draft.freq, draft.bw, draft.sf, draft.cr) != (original.freq, original.bw, original.sf, original.cr) { n += 1 }
        if draft.tx != original.tx { n += 1 }
        return n
    }

    private var saveBar: some View {
        HStack {
            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.isError ? .orange : .green)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Back up settings") { backUp() }
            Button("Revert") { draft = original }.disabled(changeCount == 0)
            Button("Apply \(changeCount) change\(changeCount == 1 ? "" : "s")") { Task { await apply() } }
                .buttonStyle(.borderedProminent).disabled(changeCount == 0)
        }
        .padding(12)
        .background(.bar)
    }

    private func loadDraft() {
        guard let me = session.selfInfo else { return }
        draft = Draft(name: me.name, lat: String(me.latitude), lon: String(me.longitude),
                      freq: String(me.frequencyMHz), bw: String(me.bandwidthKHz),
                      sf: me.spreadingFactor, cr: me.codingRate, tx: me.txPowerDBm)
        original = draft
    }

    private func run(_ success: String, _ op: @escaping (CompanionClient) async throws -> Void) {
        guard let c = session.companion else { return }
        Task {
            busy = true; defer { busy = false }
            do { try await op(c); message = .init(text: success, isError: false) } catch {
                message = .init(text: error.localizedDescription, isError: true)
            }
        }
    }

    private func apply() async {
        guard let c = session.companion else { return }
        busy = true; defer { busy = false }
        do {
            if draft.name != original.name { try await c.setName(draft.name) }
            if draft.lat != original.lat || draft.lon != original.lon {
                guard let lat = Double(draft.lat), let lon = Double(draft.lon), abs(lat) <= 90, abs(lon) <= 180 else {
                    throw FormError("Latitude and longitude must be valid degrees.")
                }
                try await c.setLocation(latitude: lat, longitude: lon)
            }
            if (draft.freq, draft.bw, draft.sf, draft.cr) != (original.freq, original.bw, original.sf, original.cr) {
                guard let f = Double(draft.freq), let bw = Double(draft.bw), (300...2500).contains(f), (7.8...500).contains(bw) else {
                    throw FormError("Frequency must be 300–2500 MHz and bandwidth 7.8–500 kHz.")
                }
                try await c.setRadio(frequencyMHz: f, bandwidthKHz: bw, spreadingFactor: draft.sf, codingRate: draft.cr)
            }
            if draft.tx != original.tx { try await c.setTxPower(draft.tx) }
            let (info, me) = try await c.handshake()
            session.deviceInfo = info; session.selfInfo = me
            loadDraft()
            message = .init(text: "Settings applied", isError: false)
        } catch {
            message = .init(text: error.localizedDescription, isError: true)
        }
    }

    private func backUp() {
        Task {
            do { try await model.backUp(session); message = .init(text: "Backup saved", isError: false) } catch {
                message = .init(text: error.localizedDescription, isError: true)
            }
        }
    }

    private func loadContacts() async {
        guard let c = session.companion else { return }
        busy = true; defer { busy = false }
        do { contacts = try await c.contacts().sorted { $0.lastAdvert > $1.lastAdvert } } catch {
            message = .init(text: error.localizedDescription, isError: true)
        }
    }

    private func refreshStatus() async {
        guard let c = session.companion else { return }
        busy = true; defer { busy = false }
        var lines: [String] = []
        if let b = try? await c.battery() {
            session.battery = b
            lines.append("battery \(b.millivolts) mV" + (b.totalKB.map { " · storage \(b.usedKB ?? 0)/\($0) kB" } ?? ""))
        }
        if case .core(_, let up, _, let q)? = try? await c.stats(0) { lines.append("uptime \(up / 3600)h \(up % 3600 / 60)m · queue \(q)") }
        if case .radio(let nf, let rssi, let snr, let tx, let rx)? = try? await c.stats(1) {
            lines.append("noise \(nf) dBm · last RSSI \(rssi) dBm · SNR \(snr) dB · airtime tx \(tx)s rx \(rx)s")
        }
        if case .packets(let r, let s, _, _, _, _)? = try? await c.stats(2) { lines.append("packets rx \(r) · tx \(s)") }
        status = lines.isEmpty ? ["No status available from this firmware"] : lines
    }
}

struct FormError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Repeater / room server

struct RepeaterConfigView: View {
    @Environment(AppModel.self) private var model
    let session: DeviceSession

    @State private var values: [String: String] = [:]
    @State private var unsupported: Set<String> = []
    @State private var edits: [String: String] = [:]
    @State private var loaded = false
    @State private var busy = false
    @State private var progress: Double?
    @State private var message: CompanionConfigView.Message?
    @State private var tab = Tab.settings

    enum Tab: String, CaseIterable { case settings = "Settings", actions = "Actions", console = "Console" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).padding(.vertical, 10)

            switch tab {
            case .settings: settingsForm
            case .actions: ActionsPane(session: session)
            case .console: ConsolePane(session: session)
            }
        }
        .task { if !loaded { await readAll() } }
        .onChange(of: model.settingsRefreshRequest) { _, _ in Task { await readAll() } }
        .onChange(of: model.pendingPreset) { _, pending in
            guard let pending, loaded else { return }
            applyPreset(pending.preset); model.pendingPreset = nil; tab = .settings
        }
    }

    private var changed: [String] { edits.filter { values[$0.key] != $0.value }.map(\.key) }

    private var settingsForm: some View {
        Form {
            ForEach(CLICatalog.groups, id: \.self) { group in
                Section(group) {
                    ForEach(CLICatalog.all.filter { $0.group == group }) { setting in
                        SettingRow(setting: setting, text: binding(for: setting),
                                   isChanged: changed.contains(setting.id), unsupported: unsupported.contains(setting.id),
                                   loaded: loaded, onPreset: { applyPreset($0) })
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
    }

    /// Stages a preset in the radio setting. The preset's path-hash suggestion is mentioned but not applied: that's a
    /// routing setting you may want to choose separately.
    private func applyPreset(_ p: RadioPreset) {
        edits["radio"] = p.cliValue
        let hash = p.pathHashSize.map { " It also uses \($0)-byte path hashes; change “Path hash size” under Routing if you want that." } ?? ""
        message = .init(text: "\(p.title) preset staged. Apply to write it to the device, then reboot.\(hash)", isError: false)
    }

    private func binding(for s: CLISetting) -> Binding<String> {
        Binding(get: { edits[s.id] ?? values[s.id] ?? "" }, set: { edits[s.id] = $0 })
    }

    private var saveBar: some View {
        HStack {
            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.isError ? .orange : .green).lineLimit(2)
            }
            Spacer()
            if busy { if let progress { ProgressView(value: progress).frame(width: 90) } else { ProgressView().controlSize(.small) } }
            Button("Read from device") { Task { await readAll() } }
            Button("Back up settings") { Task { await backUp() } }.disabled(!loaded)
            Button("Revert") { edits = [:] }.disabled(changed.isEmpty)
            Button("Apply \(changed.count) change\(changed.count == 1 ? "" : "s")") { Task { await apply() } }
                .buttonStyle(.borderedProminent).disabled(changed.isEmpty)
        }
        .padding(12)
        .background(.bar)
    }

    private func readAll() async {
        guard let cli = session.cli else { return }
        busy = true; progress = 0; defer { busy = false; progress = nil }
        do {
            let result = try await cli.readAll(CLICatalog.all) { done, total in
                Task { @MainActor in progress = Double(done) / Double(total) }
            }
            values = [:]; unsupported = []
            for (id, r) in result {
                switch r {
                case .value(let v): values[id] = v
                case .unsupported: unsupported.insert(id)
                }
            }
            edits = [:]
            loaded = true
            message = .init(text: "Read \(values.count) settings", isError: false)
        } catch {
            message = .init(text: error.localizedDescription, isError: true)
        }
    }

    private func apply() async {
        guard let cli = session.cli else { return }
        busy = true; defer { busy = false }
        var rebootNeeded = false
        do {
            for id in changed.sorted() {
                guard let setting = CLICatalog.setting(id), let value = edits[id] else { continue }
                if let problem = validate(setting, value) { throw FormError("\(setting.label): \(problem)") }
                let reply = try await cli.write(setting, value: value)
                if reply.lowercased().hasPrefix("err") { throw FormError("\(setting.label): \(reply)") }
                values[id] = value
                rebootNeeded = rebootNeeded || setting.requiresReboot
            }
            edits = [:]
            message = .init(text: rebootNeeded ? "Applied. Reboot the device for radio changes to take effect." : "Applied", isError: false)
        } catch {
            message = .init(text: error.localizedDescription, isError: true)
        }
    }

    private func validate(_ s: CLISetting, _ value: String) -> String? {
        switch s.kind {
        case .number(let range):
            guard let d = Double(value), range.contains(d) || (s.allowsZero && d == 0) else { return "must be a number from \(range.lowerBound) to \(range.upperBound)\(s.allowsZero ? ", or 0 to turn it off" : "")" }
        case .radio:
            let p = value.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count == 4, p.allSatisfy({ $0 != nil }) else { return "use freq,bw,sf,cr (e.g. 910.525,62.5,7,5)" }
        case .choice(let options):
            guard options.contains(value) else { return "must be one of \(options.joined(separator: ", "))" }
        case .onOff:
            guard ["on", "off"].contains(value) else { return "must be on or off" }
        default: break
        }
        return nil
    }

    private func backUp() async {
        do { try await model.backUp(session, repeaterValues: values.filter { id, _ in CLICatalog.setting(id)?.sensitive == false }); message = .init(text: "Backup saved", isError: false) } catch {
            message = .init(text: error.localizedDescription, isError: true)
        }
    }
}

struct SettingRow: View {
    let setting: CLISetting
    @Binding var text: String
    let isChanged: Bool
    let unsupported: Bool
    let loaded: Bool
    var onPreset: ((RadioPreset) -> Void)?

    var body: some View {
        LabeledContent {
            if unsupported {
                Text("Not supported by this firmware").font(.callout).foregroundStyle(.tertiary)
            } else if !loaded {
                Text("—").foregroundStyle(.tertiary)
            } else {
                control
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(setting.label)
                    if isChanged { Circle().fill(.orange).frame(width: 6, height: 6) }
                    if setting.requiresReboot { Image(systemName: "restart").font(.caption2).foregroundStyle(.secondary).help("Needs a reboot to take effect") }
                }
                Text(setting.help).font(.caption).foregroundStyle(.secondary)
                if case .radio = setting.kind, !unsupported, loaded { PresetMatchNote(values: RadioValues(cli: text)) }
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch setting.kind {
        case .radio:
            HStack {
                TextField("freq,bw,sf,cr", text: $text).textFieldStyle(.roundedBorder).frame(width: 220)
                if let onPreset { RadioPresetMenu(current: RadioValues(cli: text), apply: onPreset) }
            }
        case .onOff:
            Toggle("", isOn: Binding(get: { text.lowercased() == "on" }, set: { text = $0 ? "on" : "off" })).labelsHidden()
        case .choice(let options):
            Picker("", selection: $text) { ForEach(options, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 140)
        case .secret:
            SecureField("", text: $text).frame(width: 220)
        default:
            TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: setting.id == "radio" || setting.id == "name" ? 240 : 120)
        }
    }
}

struct ActionsPane: View {
    @Environment(AppModel.self) private var model
    let session: DeviceSession
    @State private var output = ""
    @State private var running: String?
    @State private var confirmErase = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(CLICommand.quickActions) { action in
                        Button {
                            if action.destructive { confirmErase = true } else { Task { await run(action) } }
                        } label: {
                            Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .controlSize(.large)
                        .tint(action.destructive ? .red : nil)
                        .disabled(running != nil)
                    }
                }
                if !output.isEmpty {
                    Text(output).font(.callout.monospaced()).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(24)
        }
        .confirmationDialog("Factory reset this device?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) {
                Task { await run(CLICommand.quickActions.first { $0.id == "erase" }!) }
            }
        } message: {
            Text("This erases the node's settings and identity. It cannot be undone. Back up first if you may want to restore.")
        }
    }

    private func run(_ action: CLICommand) async {
        guard let cli = session.cli else { return }
        running = action.id; defer { running = nil }
        do {
            let reply = try await cli.run(action.resolvedCommand, timeout: action.expectsReply ? .seconds(3) : .seconds(1))
            output = reply.isEmpty ? "\(action.title): sent" : reply
        } catch {
            output = error.localizedDescription
        }
    }
}

struct ConsolePane: View {
    let session: DeviceSession
    @State private var input = ""
    @State private var history: [String] = ["Type a CLI command, for example: get radio"]
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(history.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.callout.monospaced())
                                .foregroundStyle(line.hasPrefix("> ") ? Color.accentColor : .primary)
                                .textSelection(.enabled).id(i)
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: history.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            Divider()
            HStack {
                Text(">").font(.body.monospaced()).foregroundStyle(.secondary)
                TextField("command", text: $input).textFieldStyle(.plain).font(.body.monospaced())
                    .focused($focused).onSubmit { Task { await send() } }
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private func send() async {
        let cmd = input.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, let cli = session.cli else { return }
        input = ""; busy = true; defer { busy = false; focused = true }
        history.append("> \(cmd)")
        do {
            let reply = try await cli.run(cmd)
            history.append(reply.isEmpty ? "(no reply)" : reply)
        } catch {
            history.append("error: \(error.localizedDescription)")
        }
    }
}
