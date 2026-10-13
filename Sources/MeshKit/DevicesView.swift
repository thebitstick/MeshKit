import MeshKitCore
import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let session = model.session { ConnectedCard(session: session) }

                if let error = model.connectError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                Card("USB serial", symbol: "cable.connector", footnote: "ESP32 boards reset when a port is opened, so connecting takes a moment.") {
                    if model.ports.isEmpty {
                        EmptyRow(text: model.vendor == .meshcore
                            ? "No USB serial devices found. Plug in a board running MeshCore companion (USB), repeater or room server firmware, using a data cable."
                            : "No USB serial devices found. Plug in a board running Meshtastic firmware, using a data cable.")
                    }
                    ForEach(model.ports) { port in
                        HStack {
                            Image(systemName: "memorychip").foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading) {
                                Text(port.displayName).font(.body.monospaced())
                                Text(port.hint).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.connectingTo == port.displayName { ProgressView().controlSize(.small) }
                            if port.path.contains("usbmodem") {
                                Button("DFU") { Task { await model.enterDFUMode(port: port) } }
                                    .help("Restart this nRF52 board into DFU mode, whatever firmware it runs")
                                    .disabled(model.connectingTo != nil)
                            }
                            Button("Connect") { Task { await model.connect(port: port); if model.session != nil { model.showingDevices = false } } }
                                .disabled(model.connectingTo != nil || model.session?.portName == port.displayName)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Card("UF2 bootloader volumes", symbol: "externaldrive", footnote: "The DFU button next to an nRF52 board's serial port restarts a Meshtastic node into this drive. Other firmware restarts into serial DFU, which has no drive and takes Install over USB serial; double-tap reset for the drive.") {
                    if model.uf2Volumes.isEmpty { EmptyRow(text: "No UF2 bootloader drives mounted.") }
                    ForEach(model.uf2Volumes) { v in
                        HStack {
                            Image(systemName: "externaldrive.fill").foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading) {
                                Text(v.name).font(.body.monospaced())
                                Text([v.model, v.boardID].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Install firmware…") { finish(opening: .firmware) }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Card("Demo devices", symbol: "testtube.2", footnote: "Simulated radios for trying the interface without hardware.") {
                    HStack {
                        if model.vendor == .meshcore {
                            Button { Task { await model.connectDemo(.companion); finish(opening: .configure) } } label: {
                                Label("Demo companion", systemImage: "iphone.radiowaves.left.and.right")
                            }
                            Button { Task { await model.connectDemo(.repeater); finish(opening: .configure) } } label: {
                                Label("Demo repeater", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        } else {
                            Button { Task { await model.connectDemo(.meshtastic); finish(opening: .configure) } } label: {
                                Label("Demo Meshtastic", systemImage: "point.3.connected.trianglepath.dotted")
                            }
                        }
                        Spacer()
                    }
                    .disabled(model.connectingTo != nil)
                }
            }
            .padding(16)
        }
        .frame(width: 440)
        .frame(maxHeight: 620)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func finish(opening section: AppModel.Section? = nil) {
        if let section { model.section = section }
        model.showingDevices = false
    }
}

struct ConnectedCard: View {
    @Environment(AppModel.self) private var model
    let session: DeviceSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: session.kind == .companion ? "iphone.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 24)).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title).font(.headline)
                HStack {
                    if session.isDemo { Pill(text: "Demo") }
                    Pill(text: session.kindLabel)
                }
                if !session.firmwareSummary.isEmpty {
                    Text(session.firmwareSummary).foregroundStyle(.secondary)
                }
                if let me = session.selfInfo {
                    Text("Public key \(me.publicKeyHex.prefix(16))…").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let b = session.battery {
                    Label("\(Double(b.millivolts) / 1000, specifier: "%.2f") V (~\(b.approxPercent)%)", systemImage: "battery.75percent")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button("Configure") { model.section = .configure; model.showingDevices = false }.buttonStyle(.borderedProminent)
                Button("Disconnect") { model.disconnect() }
            }
        }
        .padding(14)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.green.opacity(0.35)))
    }
}

// MARK: - Shared bits

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    var footnote: String?
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.footnote = footnote; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct EmptyRow: View {
    let text: String
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary) }
}

struct Pill: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }
}
