import MeshKitCore
import MeshtasticProtobufs
import SwiftUI

@MainActor @Observable
final class DeviceSession: Identifiable {
    enum Kind { case companion, repeater, meshtastic }

    let kind: Kind
    let title: String
    let portName: String
    let isDemo: Bool
    let transport: ByteTransport
    var companion: CompanionClient?
    var cli: RepeaterCLIClient?
    var meshtastic: MeshtasticClient?
    var meshtasticState: MeshtasticNodeState?

    var deviceInfo: DeviceInfo?
    var selfInfo: SelfInfo?
    var battery: BatteryInfo?
    var repeaterVersion = ""
    var repeaterBoard = ""
    var nodeName = ""

    init(kind: Kind, title: String, portName: String, isDemo: Bool, transport: ByteTransport) {
        self.kind = kind; self.title = title; self.portName = portName; self.isDemo = isDemo; self.transport = transport
    }

    var kindLabel: String {
        switch kind {
        case .companion: "MeshCore companion"
        case .repeater: "MeshCore repeater / room server"
        case .meshtastic: "Meshtastic"
        }
    }

    var supportsAdvert: Bool { kind != .meshtastic }

    var firmwareSummary: String {
        switch kind {
        case .companion: [deviceInfo?.semanticVersion, deviceInfo?.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .repeater: [repeaterVersion, repeaterBoard].filter { !$0.isEmpty }.joined(separator: " · ")
        case .meshtastic:
            [meshtasticState?.metadata?.firmwareVersion.nonEmpty.map { "v\($0)" },
             meshtasticState?.metadata.map { prettyBoardName(String(describing: $0.hwModel)) }].compactMap { $0 }.joined(separator: " · ")
        }
    }

    func close() {
        let c = companion, r = cli, m = meshtastic, t = transport
        companion = nil; cli = nil; meshtastic = nil
        Task { await c?.stop(); await r?.stop(); await m?.stop(); t.close() }
    }
}

@MainActor @Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case firmware = "Firmware", configure = "Configure", backups = "Backups", log = "Log"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .firmware: "square.and.arrow.down.on.square"
            case .configure: "slider.horizontal.3"
            case .backups: "externaldrive.badge.timemachine"
            case .log: "text.alignleft"
            }
        }
    }

    var section: Section? = .firmware
    /// Whether the toolbar's device popover is open.
    var showingDevices = false

    var ports: [SerialPortInfo] = []
    var uf2Volumes: [UF2Volume] = []

    var session: DeviceSession?
    var connectingTo: String?
    var connectError: String?

    var snapshots: [ConfigSnapshot] = []
    var pendingFlash: FlashRequest?

    var radioPresets: [RadioPreset] = RadioPresets.bundled
    var radioPresetSource: RadioPresetSource = .bundled
    var userPresets: [RadioPreset] = []
    var pendingPreset: PendingPreset?

    struct PendingPreset: Identifiable, Equatable {
        let id = UUID()
        let preset: RadioPreset
    }
    var notice: Notice?
    var activity: String?
    var settingsRefreshRequest = 0

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }
    var flashBackups: [FlashBackupStore.Entry] = []
    var nrfBackups: [NRF52BackupStore.Entry] = []
    var logLines: [String] = []

    let vendor: FirmwareVendor
    let firmware: FirmwareModel

    init(vendor: FirmwareVendor) {
        self.vendor = vendor
        firmware = FirmwareModel(vendor: vendor)
        refreshDevices()
        snapshots = SnapshotStore.list()
        flashBackups = FlashBackupStore.list()
        nrfBackups = NRF52BackupStore.list()
        if vendor == .meshcore {
            userPresets = UserRadioPresetStore().list()
            Task { await loadRadioPresets() }
        }

        guard let launch = LaunchOptions.current, launch.vendor == vendor else { return }
        if let s = launch.section { section = s }
        if let role = launch.role { firmware.role = role }
        if let pick = launch.select { firmware.autoSelect = pick }
        if let file = launch.flashFile { pendingFlash = .localFile(file) }
        if let demo = launch.demo { Task { await connectDemo(demo) } }
    }

    var visibleSnapshots: [ConfigSnapshot] {
        snapshots.filter { vendor == .meshtastic ? $0.kind == .meshtastic : $0.kind != .meshtastic }
    }

    // MARK: Discovery

    /// Looks for serial ports and UF2 drives now. Reading mounted volumes can stall (a sleeping network share, say),
    /// so the repeating poll does it off the main thread; this immediate form is for launch and the Refresh command.
    func refreshDevices() { apply(SerialDiscovery.list(), UF2Volumes.detect()) }

    private func apply(_ newPorts: [SerialPortInfo], _ newVolumes: [UF2Volume]) {
        // Only publish real changes: assigning an equal value still invalidates every view (and the menus) watching it.
        if newPorts != ports { ports = newPorts }
        if newVolumes != uf2Volumes { uf2Volumes = newVolumes }

        if let s = session, !s.isDemo, !newPorts.contains(where: { $0.displayName == s.portName }) {
            let name = s.title
            disconnect()
            log("\(name) disappeared from the USB bus")
            show(Notice(text: "\(name) was disconnected.", isError: true))
        }
    }

    func startPolling() async {
        while !Task.isCancelled {
            let found = await Task.detached(priority: .utility) { (SerialDiscovery.list(), UF2Volumes.detect()) }.value
            apply(found.0, found.1)
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    // MARK: Connecting

    func log(_ line: String) {
        let stamp = Date.now.formatted(.dateTime.hour().minute().second())
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 800 { logLines.removeFirst(logLines.count - 800) }
    }

    private var logger: @Sendable (String) -> Void {
        { [weak self] line in Task { @MainActor in self?.log(line) } }
    }

    func connect(port: SerialPortInfo) async {
        guard connectingTo == nil else { return }
        connectingTo = port.displayName
        connectError = nil
        defer { connectingTo = nil }
        do {
            let transport = try SerialPort(path: port.path)
            log("Opened \(port.path)")
            // USB-UART bridges toggle DTR/RTS on open, which resets ESP32 boards; give them time to boot.
            try await Task.sleep(for: .milliseconds(1400))
            try await open(transport: transport, title: port.displayName, portName: port.displayName, isDemo: false)
        } catch {
            connectError = error.localizedDescription
            log("Connect failed: \(error.localizedDescription)")
        }
    }

    func connectDemo(_ kind: DeviceSession.Kind) async {
        guard connectingTo == nil else { return }
        connectingTo = "demo"
        connectError = nil
        defer { connectingTo = nil }
        do {
            let transport: ByteTransport
            let title: String
            switch kind {
            case .companion: transport = SimulatedCompanionTransport(); title = "Demo Companion"
            case .repeater: transport = SimulatedRepeaterTransport(); title = "Demo Repeater"
            case .meshtastic: transport = SimulatedMeshtasticNode(); title = "Demo Meshtastic"
            }
            try await open(transport: transport, title: title, portName: "simulated", isDemo: true)
        } catch {
            connectError = error.localizedDescription
        }
    }

    private func open(transport: ByteTransport, title: String, portName: String, isDemo: Bool) async throws {
        disconnect()
        do {
            do {
                try await probe(transport: transport, title: title, portName: portName, isDemo: isDemo)
            } catch ProbeError.noFirmware where !isDemo {
                // A board that has just been flashed or reset can take several seconds to start answering.
                log("No answer yet; giving the board a few more seconds to boot")
                try await Task.sleep(for: .seconds(4))
                try await probe(transport: transport, title: title, portName: portName, isDemo: isDemo)
            }
        } catch {
            transport.close()
            throw error
        }
    }

    private func probe(transport: ByteTransport, title: String, portName: String, isDemo: Bool) async throws {

        if vendor == .meshtastic {
            let mesh = MeshtasticClient(transport: transport, logger: logger)
            if await mesh.probe(timeout: 2.5), let state = try? await mesh.connect() {
                let name = state.owner?.longName.nonEmpty ?? title
                let s = DeviceSession(kind: .meshtastic, title: name, portName: portName, isDemo: isDemo, transport: transport)
                s.meshtastic = mesh; s.meshtasticState = state
                session = s
                log("Meshtastic node detected: \(state.nodeID) \(state.metadata?.firmwareVersion ?? "")")
                return
            }
            await mesh.stop()
            throw ProbeError.noFirmware(vendor)
        }

        let companion = CompanionClient(transport: transport, logger: logger)
        await companion.start()
        if let (info, me) = try? await companion.handshake() {
            let s = DeviceSession(kind: .companion, title: me.name.isEmpty ? title : me.name, portName: portName, isDemo: isDemo, transport: transport)
            s.companion = companion; s.deviceInfo = info; s.selfInfo = me
            s.battery = try? await companion.battery()
            session = s
            log("Companion detected: \(info.model) \(info.semanticVersion)")
            return
        }
        await companion.stop()

        let cli = RepeaterCLIClient(transport: transport, logger: logger)
        await cli.start()
        _ = try? await cli.run("", quiet: .milliseconds(150), timeout: .milliseconds(400))   // flush any garbage
        let ident: (version: String, board: String)
        do { ident = try await cli.identify() } catch { await cli.stop(); throw error }
        guard ident.version.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil else {
            await cli.stop()
            throw ProbeError.noFirmware(vendor)
        }
        var nodeName = ""
        if case .value(let name)? = try? await cli.read(CLICatalog.setting("name")!) { nodeName = name }
        let s = DeviceSession(kind: .repeater, title: nodeName.isEmpty ? title : nodeName, portName: portName, isDemo: isDemo, transport: transport)
        s.cli = cli; s.repeaterVersion = ident.version; s.repeaterBoard = ident.board; s.nodeName = nodeName
        session = s
        log("Repeater CLI detected: \(ident.version)")
    }

    enum ProbeError: LocalizedError {
        case noFirmware(FirmwareVendor)
        var errorDescription: String? {
            switch self {
            case .noFirmware(.meshcore):
                "Nothing answered like MeshCore firmware. Check that the board runs MeshCore companion (USB), repeater or room-server firmware. A Meshtastic node needs the Meshtastic window."
            case .noFirmware(.meshtastic):
                "Nothing answered like Meshtastic firmware. Check that the board runs Meshtastic with its serial API enabled. A MeshCore device needs the MeshCore window."
            }
        }
    }

    func disconnect() {
        session?.close()
        session = nil
    }

    // MARK: Actions (shared by the menu bar and the views)

    func perform(_ label: String, _ operation: () async throws -> String?) async {
        activity = label
        defer { activity = nil }
        do {
            let message = try await operation()
            show(Notice(text: message ?? label, isError: false))
        } catch {
            show(Notice(text: error.localizedDescription, isError: true))
        }
    }

    func show(_ notice: Notice) {
        self.notice = notice
        let id = notice.id
        Task {
            try? await Task.sleep(for: .seconds(notice.isError ? 8 : 4))
            if self.notice?.id == id { self.notice = nil }
        }
    }

    var canSendCommands: Bool { session != nil }
    var canSendAdvert: Bool { session?.supportsAdvert == true }

    func sendAdvert() async {
        guard let session else { return }
        await perform("Sending advert") {
            switch session.kind {
            case .companion: try await session.companion?.sendAdvert(flood: true)
            case .repeater: try await session.cli?.runChecked("advert")
            case .meshtastic: throw FormError("Meshtastic nodes announce themselves automatically; there's no manual advert.")
            }
            return "Advert sent"
        }
    }

    func syncClock() async {
        guard let session else { return }
        await perform("Syncing clock") {
            switch session.kind {
            case .companion: try await session.companion?.syncClock()
            case .repeater: try await session.cli?.runChecked("time \(Int(Date().timeIntervalSince1970))")
            case .meshtastic: try await session.meshtastic?.syncClock()
            }
            return "Clock synced"
        }
    }

    /// nRF52 boards show up as native USB (`usbmodem`) serial ports.
    var dfuCandidatePorts: [SerialPortInfo] { ports.filter { $0.path.contains("usbmodem") } }

    /// Puts an nRF52 board into DFU mode whatever firmware it runs, and says what happened.
    func enterDFUMode(port: SerialPortInfo, wantsDrive: Bool = false) async {
        if session?.portName == port.displayName { disconnect(); try? await Task.sleep(for: .milliseconds(300)) }
        await perform("Entering DFU mode") {
            let log = logger
            switch try await NRF52DFUMode.enter(path: port.path, logger: { log("dfu: \($0)") }) {
            case .uf2Drive: return "The node is restarting into its UF2 bootloader. Its drive appears in a few seconds."
            case .serialDFU:
                return wantsDrive
                    ? "This firmware restarts into serial DFU, which has no drive. Double-tap the board's reset button to get the drive instead."
                    : "The board is in serial DFU mode. It has no drive: use Install over USB serial (the ⋯ menu next to the board name) to send firmware."
            }
        }
    }

    /// Menu and sheet shortcut: the connected node's port, or the only candidate.
    func enterDFUModeOnLikelyPort(wantsDrive: Bool = false) async {
        if let s = session, let port = ports.first(where: { $0.displayName == s.portName }) { await enterDFUMode(port: port, wantsDrive: wantsDrive); return }
        guard let only = dfuCandidatePorts.first, dfuCandidatePorts.count == 1 else {
            show(Notice(text: dfuCandidatePorts.isEmpty ? "No nRF52 serial port found." : "More than one USB serial port: use the DFU button next to the right one in the device list.", isError: true))
            return
        }
        await enterDFUMode(port: only, wantsDrive: wantsDrive)
    }

    func rebootDevice() async {
        guard let session else { return }
        await perform("Rebooting") {
            switch session.kind {
            case .companion: try await session.companion?.reboot()
            case .repeater: _ = try await session.cli?.run("reboot", timeout: .seconds(1))
            case .meshtastic: try await session.meshtastic?.reboot(seconds: 3)
            }
            return "Reboot requested. Reconnect in a few seconds."
        }
    }

    func requestSettingsRefresh() {
        section = .configure
        settingsRefreshRequest += 1
    }

    func backUpConnectedDevice() async {
        guard let session else { return }
        await perform("Backing up settings") {
            try await backUp(session)
            return "Settings backed up"
        }
    }

    func chooseImageToFlash() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Firmware Image"
        panel.message = "Pick a .uf2 or .bin file to write to a board."
        panel.allowedContentTypes = [.init(filenameExtension: "uf2"), .init(filenameExtension: "bin")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { pendingFlash = .localFile(url) }
    }

    func flashImage(at url: URL) {
        guard ["uf2", "bin"].contains(url.pathExtension.lowercased()) else {
            show(Notice(text: "\(url.lastPathComponent) isn't a .uf2 or .bin file.", isError: true)); return
        }
        pendingFlash = .localFile(url)
    }

    func revealInFinder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: Radio presets

    func loadRadioPresets(force: Bool = false) async {
        let result = await RadioPresetCatalog().load(forceRefresh: force)
        radioPresets = result.presets
        radioPresetSource = result.source
    }

    var presetsByRegion: [(region: String, presets: [RadioPreset])] {
        let grouped = Dictionary(grouping: radioPresets, by: \.region)
        return (RadioPreset.regionOrder + grouped.keys.filter { !RadioPreset.regionOrder.contains($0) }.sorted())
            .compactMap { r in grouped[r].map { (r, $0) } }
    }

    func presets(matching v: RadioValues) -> [RadioPreset] {
        (radioPresets + userPresets).filter { v.matches($0) }
    }

    func saveUserPreset(_ preset: RadioPreset) throws { userPresets = try UserRadioPresetStore().save(preset) }
    func deleteUserPreset(_ preset: RadioPreset) { userPresets = (try? UserRadioPresetStore().delete(preset)) ?? userPresets }

    func stagePreset(_ preset: RadioPreset) {
        section = .configure
        pendingPreset = PendingPreset(preset: preset)
    }

    var canStagePreset: Bool { session.map { $0.kind != .meshtastic } ?? false }

    // MARK: Snapshots

    func reloadSnapshots() { snapshots = SnapshotStore.list() }
    func reloadFlashBackups() { flashBackups = FlashBackupStore.list(); nrfBackups = NRF52BackupStore.list() }

    func backUp(_ session: DeviceSession, repeaterValues: [String: String]? = nil) async throws {
        var values: [String: String] = [:]
        switch session.kind {
        case .companion:
            guard let me = session.selfInfo else { return }
            values = ["name": me.name, "lat": String(me.latitude), "lon": String(me.longitude),
                      "radio": "\(me.frequencyMHz),\(me.bandwidthKHz),\(me.spreadingFactor),\(me.codingRate)",
                      "tx": String(me.txPowerDBm)]
        case .meshtastic:
            guard let st = session.meshtasticState else { return }
            values = MeshtasticValues.snapshot(of: st)
        case .repeater:
            if let repeaterValues { values = repeaterValues } else if let cli = session.cli {
                for (id, result) in try await cli.readAll(CLICatalog.backupable) {
                    if case .value(let v) = result { values[id] = v }
                }
            }
        }
        let snapKind: ConfigSnapshot.Kind = switch session.kind { case .companion: .companion; case .repeater: .repeater; case .meshtastic: .meshtastic }
        let snap = ConfigSnapshot(kind: snapKind, deviceName: session.title,
                                  board: session.deviceInfo?.model ?? session.meshtasticState.map { prettyBoardName(String(describing: $0.metadata?.hwModel ?? .unset)) } ?? session.repeaterBoard,
                                  firmware: session.deviceInfo?.semanticVersion ?? session.meshtasticState?.metadata?.firmwareVersion ?? session.repeaterVersion, values: values)
        try SnapshotStore.save(snap)
        reloadSnapshots()
        log("Saved backup of \(session.title) (\(values.count) settings)")
    }

    func restore(_ snapshot: ConfigSnapshot, to session: DeviceSession) async throws -> Int {
        var written = 0
        switch (snapshot.kind, session.kind) {
        case (.repeater, .repeater):
            guard let cli = session.cli else { return 0 }
            for (id, value) in snapshot.values.sorted(by: { $0.key < $1.key }) {
                guard let setting = CLICatalog.setting(id), !setting.sensitive else { continue }
                _ = try await cli.write(setting, value: value)
                written += 1
            }
        case (.companion, .companion):
            guard let c = session.companion else { return 0 }
            let v = snapshot.values
            if let name = v["name"] { try await c.setName(name); written += 1 }
            if let lat = v["lat"].flatMap(Double.init), let lon = v["lon"].flatMap(Double.init) {
                try await c.setLocation(latitude: lat, longitude: lon); written += 1
            }
            let r = (v["radio"] ?? "").split(separator: ",").map(String.init)
            if r.count == 4, let f = Double(r[0]), let bw = Double(r[1]), let sf = Int(r[2]), let cr = Int(r[3]) {
                try await c.setRadio(frequencyMHz: f, bandwidthKHz: bw, spreadingFactor: sf, codingRate: cr); written += 1
            }
            if let tx = v["tx"].flatMap(Int.init) { try await c.setTxPower(tx); written += 1 }
            if let (info, me) = try? await c.handshake() { session.deviceInfo = info; session.selfInfo = me }
        case (.meshtastic, .meshtastic):
            guard let mt = session.meshtastic, let st = session.meshtasticState else { return 0 }
            let edit = MeshtasticValues.edit(from: snapshot.values, current: st)
            try await mt.apply(edit)
            written = snapshot.values.count
        default:
            throw RestoreError.kindMismatch
        }
        log("Restored \(written) settings to \(session.title)")
        return written
    }

    enum RestoreError: LocalizedError {
        case kindMismatch
        var errorDescription: String? { "This backup is for a different kind of device than the one connected." }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Command-line switches for development and screenshots.
struct LaunchOptions {
    var vendor: FirmwareVendor
    var section: AppModel.Section?
    var role: MeshCoreRole?
    var select: String?
    var flashFile: URL?
    var demo: DeviceSession.Kind?

    static let current: LaunchOptions? = {
        let args = ProcessInfo.processInfo.arguments.dropFirst()
        func arg(_ name: String) -> String? { args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) } }
        let names = ["vendor", "section", "role", "select", "flash-file", "demo"]
        guard names.contains(where: { arg($0) != nil }) else { return nil }
        let demo: DeviceSession.Kind? = arg("demo").map { $0 == "repeater" ? .repeater : $0 == "meshtastic" ? .meshtastic : .companion }
        let vendor: FirmwareVendor = arg("vendor") == "meshtastic" || demo == .meshtastic ? .meshtastic : .meshcore
        return LaunchOptions(
            vendor: vendor,
            section: arg("section").flatMap { name in AppModel.Section.allCases.first { $0.rawValue.lowercased() == name } },
            role: arg("role").flatMap { r in MeshCoreRole.allCases.first { $0.rawValue == r } },
            select: arg("select")?.lowercased(),
            flashFile: arg("flash-file").map { URL(fileURLWithPath: $0) },
            demo: demo)
    }()
}
