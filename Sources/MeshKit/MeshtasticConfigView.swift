import MeshKitCore
import MeshtasticProtobufs
import SwiftUI

struct MeshtasticConfigView: View {
    @Environment(AppModel.self) private var model
    let session: DeviceSession

    struct Draft: Equatable {
        var longName = "", shortName = ""
        var region = Config.LoRaConfig.RegionCode.unset
        var preset = Config.LoRaConfig.ModemPreset.longFast
        var hopLimit = 3
        var txEnabled = true
        var txPower = 0
        var role = Config.DeviceConfig.Role.client
    }

    @State private var draft = Draft()
    @State private var original = Draft()
    @State private var busy = false
    @State private var message: CompanionConfigView.Message?

    private var state: MeshtasticNodeState? { session.meshtasticState }
    private var isManaged: Bool { state?.device?.isManaged == true }

    var body: some View {
        Form {
            if isManaged {
                Section {
                    Label("This node is managed by a remote administrator. It ignores changes made from here, so settings are read-only.",
                          systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                }
            }

            if let state {
                Section("Node") {
                    LabeledContent("Node ID", value: state.nodeID)
                    LabeledContent("Hardware", value: prettyBoardName(String(describing: state.metadata?.hwModel ?? .unset)))
                    LabeledContent("Firmware", value: state.metadata?.firmwareVersion.nonEmpty.map { "v\($0)" } ?? "Unknown")
                    LabeledContent("Reboots", value: String(state.myInfo?.rebootCount ?? 0))
                    if let key = state.owner?.publicKey, !key.isEmpty {
                        LabeledContent("Public key") {
                            Text(key.base64EncodedString()).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                        }
                    }
                }
            }

            Section("Owner") {
                TextField("Long name", text: $draft.longName)
                TextField("Short name (4 characters)", text: $draft.shortName)
                    .onChange(of: draft.shortName) { _, new in if new.count > 4 { draft.shortName = String(new.prefix(4)) } }
            }

            Section {
                Picker("Region", selection: $draft.region) {
                    ForEach(Config.LoRaConfig.RegionCode.allCases, id: \.self) { Text(MeshtasticLabels.region($0)).tag($0) }
                }
                Picker("Modem preset", selection: $draft.preset) {
                    ForEach(Config.LoRaConfig.ModemPreset.allCases, id: \.self) { Text(MeshtasticLabels.modemPreset($0)).tag($0) }
                }
                Stepper("Hop limit: \(draft.hopLimit)", value: $draft.hopLimit, in: 0...7)
                Toggle("Transmit enabled", isOn: $draft.txEnabled)
                Stepper(draft.txPower == 0 ? "TX power: default" : "TX power: \(draft.txPower) dBm", value: $draft.txPower, in: 0...30)
            } header: {
                Text("LoRa radio")
            } footer: {
                Text(draft.region == .unset ? "Choose your region before the radio will transmit. Using the wrong region may be illegal where you are."
                                            : "Nodes need the same region and preset to hear each other. The node reboots to apply radio changes.")
            }

            Section("Device") {
                Picker("Role", selection: $draft.role) {
                    ForEach(Config.DeviceConfig.Role.allCases, id: \.self) { Text(MeshtasticLabels.role($0)).tag($0) }
                }
            }

            if let channels = state?.channels.filter({ $0.role != .disabled }), !channels.isEmpty {
                Section {
                    ForEach(channels, id: \.index) { c in
                        LabeledContent {
                            Text(MeshtasticLabels.keySummary(c.settings.psk)).foregroundStyle(.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.settings.name.isEmpty ? "Default (\(draft.preset.rawValue == 0 ? "Long Fast" : MeshtasticLabels.modemPreset(draft.preset)))" : c.settings.name)
                                Text("Channel \(c.index) · \(MeshtasticLabels.channelRole(c.role))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Channels") } footer: { Text("Keys are never shown here. Editing channels isn't supported yet.") }
            }

            if let nodes = state?.nodes, !nodes.isEmpty {
                Section("Mesh (\(nodes.count) nodes)") {
                    Table(NodeRow.rows(from: nodes)) {
                        TableColumn("Name", value: \.name)
                        TableColumn("Short", value: \.short).width(60)
                        TableColumn("Hops", value: \.hops).width(50)
                        TableColumn("SNR", value: \.snr).width(70)
                        TableColumn("Heard", value: \.heard).width(110)
                    }
                    .frame(height: min(CGFloat(nodes.count) * 28 + 40, 260))
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy || isManaged)
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        .onAppear(perform: loadDraft)
        .onChange(of: model.settingsRefreshRequest) { _, _ in Task { await reload() } }
    }

    private var edit: MeshtasticEdit {
        guard let state else { return MeshtasticEdit() }
        return MeshtasticValues.edit(from: values(of: draft), current: state)
    }

    private var changeCount: Int {
        let e = edit
        return (e.longName != nil ? 1 : 0) + (e.shortName != nil ? 1 : 0) + (e.lora != nil ? 1 : 0) + (e.device != nil ? 1 : 0)
    }

    private func values(of d: Draft) -> [String: String] {
        ["owner.long": d.longName, "owner.short": d.shortName, "lora.region": String(d.region.rawValue),
         "lora.preset": String(d.preset.rawValue), "lora.hop": String(d.hopLimit), "lora.txpower": String(d.txPower),
         "lora.txenabled": d.txEnabled ? "true" : "false", "device.role": String(d.role.rawValue)]
    }

    private var saveBar: some View {
        HStack {
            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.isError ? .orange : .green).lineLimit(2)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Read from node") { Task { await reload() } }
            Button("Back up settings") { Task { await backUp() } }
            Button("Revert") { draft = original }.disabled(draft == original)
            Button("Apply \(changeCount) change\(changeCount == 1 ? "" : "s")") { Task { await apply() } }
                .buttonStyle(.borderedProminent).disabled(changeCount == 0 || isManaged)
        }
        .padding(12)
        .background(.bar)
    }

    private func loadDraft() {
        guard let s = state else { return }
        draft = Draft(longName: s.owner?.longName ?? "", shortName: s.owner?.shortName ?? "",
                      region: s.lora?.region ?? .unset, preset: s.lora?.modemPreset ?? .longFast,
                      hopLimit: Int(s.lora?.hopLimit ?? 3), txEnabled: s.lora?.txEnabled ?? true,
                      txPower: Int(s.lora?.txPower ?? 0), role: s.device?.role ?? .client)
        original = draft
    }

    private func reload() async {
        guard let client = session.meshtastic else { return }
        busy = true; defer { busy = false }
        do {
            session.meshtasticState = try await client.connect()
            loadDraft()
            message = .init(text: "Read settings from the node", isError: false)
        } catch { message = .init(text: error.localizedDescription, isError: true) }
    }

    private func apply() async {
        guard let client = session.meshtastic else { return }
        busy = true; defer { busy = false }
        let changesRadio = edit.lora != nil
        do {
            try await client.apply(edit)
            // The node may reboot to apply radio changes; give it a moment, then read back what it settled on.
            try? await Task.sleep(for: .milliseconds(changesRadio ? 2500 : 600))
            if let fresh = try? await client.connect() { session.meshtastic != nil ? (session.meshtasticState = fresh) : () }
            loadDraft()
            message = .init(text: changesRadio ? "Applied. The node may reboot to use the new radio settings." : "Applied", isError: false)
        } catch {
            message = .init(text: error.localizedDescription, isError: true)
        }
    }

    private func backUp() async {
        do { try await model.backUp(session); message = .init(text: "Backup saved", isError: false) } catch {
            message = .init(text: error.localizedDescription, isError: true)
        }
    }
}

private struct NodeRow: Identifiable {
    let id: UInt32
    let name: String, short: String, hops: String, snr: String, heard: String

    static func rows(from nodes: [NodeInfo]) -> [NodeRow] {
        nodes.sorted { $0.lastHeard > $1.lastHeard }.map { n in
            NodeRow(id: n.num,
                    name: n.user.longName.isEmpty ? String(format: "!%08x", n.num) : n.user.longName,
                    short: n.user.shortName,
                    hops: n.hasHopsAway ? String(n.hopsAway) : "–",
                    snr: n.snr == 0 ? "–" : String(format: "%.1f dB", n.snr),
                    heard: n.lastHeard == 0 ? "–" : Date(timeIntervalSince1970: TimeInterval(n.lastHeard)).formatted(.relative(presentation: .named)))
        }
    }
}
