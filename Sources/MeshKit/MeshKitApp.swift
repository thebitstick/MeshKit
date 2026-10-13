import AppKit
import MeshKitCore
import SwiftUI

@MainActor final class Workspace {
    let meshcore = AppModel(vendor: .meshcore)
    let meshtastic = AppModel(vendor: .meshtastic)

    var models: [AppModel] { [meshcore, meshtastic] }
    func model(for vendor: FirmwareVendor) -> AppModel { vendor == .meshcore ? meshcore : meshtastic }
}

extension FirmwareVendor {
    var windowID: String { rawValue.lowercased() }
    var symbol: String { self == .meshcore ? "antenna.radiowaves.left.and.right" : "point.3.connected.trianglepath.dotted" }
    var tagline: String {
        self == .meshcore
            ? "Install firmware and configure companions, repeaters and room servers."
            : "Install firmware and configure Meshtastic nodes."
    }
}

private struct DeviceModelKey: FocusedValueKey { typealias Value = AppModel }
extension FocusedValues {
    var deviceModel: AppModel? {
        get { self[DeviceModelKey.self] }
        set { self[DeviceModelKey.self] = newValue }
    }
}

/// With every window closed MeshKit keeps running, and clicking its Dock icon brings the Welcome window back
/// (SwiftUI doesn't do that on its own for single windows).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Always start from the Welcome window rather than reopening whatever was open last time.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func application(_ app: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool { false }
    func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        // The Window menu lists every window scene, open or not; choosing its Welcome entry reopens it.
        if let item = NSApp.windowsMenu?.items.first(where: { $0.title == "Welcome to MeshKit" }) {
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
            return false
        }
        return true
    }
}

@main
struct MeshKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Created once in `init`. (A default value here would build a second set of models, and so of startup work.)
    @State private var workspace: Workspace
    @State private var bridge: ModelBridge

    init() {
        // Running via `swift run` (no app bundle) needs this to get a menu bar and focus.
        NSApplication.shared.setActivationPolicy(.regular)
        let workspace = Workspace()
        _workspace = State(initialValue: workspace)
        _bridge = State(initialValue: ModelBridge(workspace: workspace))
    }

    var body: some Scene {
        Window("Welcome to MeshKit", id: "welcome") {
            WelcomeView()
                .task { NSApp.activate(ignoringOtherApps: true) }
                .task { await dumpMenuIfRequested() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { MeshKitCommands(bridge: bridge) }

        Window("MeshCore", id: FirmwareVendor.meshcore.windowID) {
            RootView()
                .environment(workspace.meshcore)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 900, height: 620)
        .windowToolbarStyle(.unified(showsTitle: false))

        Window("Meshtastic", id: FirmwareVendor.meshtastic.windowID) {
            RootView()
                .environment(workspace.meshtastic)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 900, height: 620)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView(workspace: workspace)
        }
    }
}

@MainActor func openDeviceWindow(_ vendor: FirmwareVendor, _ openWindow: OpenWindowAction, _ dismissWindow: DismissWindowAction) {
    openWindow(id: vendor.windowID)
    dismissWindow(id: "welcome")
    NSApp.activate(ignoringOtherApps: true)
}

// MARK: - Menu bar

@MainActor private var menuDumped = false

/// `MESHKIT_DUMP_MENU=1` prints the main menu (titles, shortcuts, enabled state) so the structure can be checked
/// without driving the UI.
@MainActor func dumpMenuIfRequested() async {
    guard ProcessInfo.processInfo.environment["MESHKIT_DUMP_MENU"] != nil, !menuDumped else { return }
    menuDumped = true
    let delay = Double(ProcessInfo.processInfo.environment["MESHKIT_DUMP_DELAY"] ?? "") ?? 4
    try? await Task.sleep(for: .seconds(delay))
    // AppKit applies menu changes only while the app is frontmost, so a launch from a shell can read stale states;
    // MESHKIT_DUMP_ACTIVATE=1 brings the app forward first.
    if ProcessInfo.processInfo.environment["MESHKIT_DUMP_ACTIVATE"] != nil {
        for _ in 0..<5 {
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .seconds(1))
            if NSApp.isActive { break }
        }
        try? await Task.sleep(for: .seconds(2))
    }
    NSApp.mainMenu?.update()   // items are validated lazily; make the state current before reading it
    func dump(_ menu: NSMenu, indent: String) {
        for item in menu.items {
            if item.isSeparatorItem { print("\(indent)----"); continue }
            let keys = item.keyEquivalent.isEmpty ? "" : "  [\(item.keyEquivalentModifierMask.rawValue == 0 ? "" : "mods=\(item.keyEquivalentModifierMask.rawValue) ")key=\(item.keyEquivalent)]"
            print("\(indent)\(item.title)\(item.isEnabled ? "" : "  (disabled)")\(item.state == .on ? "  ✓" : "")\(keys)")
            if let sub = item.submenu { dump(sub, indent: indent + "    ") }
        }
    }
    if let main = NSApp.mainMenu { dump(main, indent: "") }
    // Packaging check: the bundled resources must resolve from wherever the app was installed.
    let stubs = ESPChip.allCases.map { c in (try? ESPStubImage.load(for: c)) != nil ? "\(c.rawValue) ok" : "\(c.rawValue) MISSING" }
    print("flasher stubs: \(stubs.joined(separator: ", "))")
    print("bundled radio presets: \(RadioPresets.bundled.count)")
    fflush(stdout)
}

/// `Commands` bodies don't track `@Observable` models, so menu items would never enable or disable themselves.
/// This re-publishes the models' changes through `ObservableObject`, which `Commands` does observe.
@MainActor final class ModelBridge {
    let workspace: Workspace
    let changes: ObservationBridge

    init(workspace: Workspace) {
        self.workspace = workspace
        changes = ObservationBridge {
            for model in workspace.models {
                _ = model.session?.id
                _ = model.ports.map(\.path)
                _ = model.radioPresets.count
                _ = model.userPresets.count
                _ = model.firmware.role
                _ = model.firmware.channel
                _ = model.firmware.mtMode
                _ = model.firmware.selectedGroup?.id
                _ = model.firmware.preferredConnection
                _ = model.firmware.mtSelectedBoard?.slug
            }
        }
    }
}

struct MeshKitCommands: Commands {
    private let bridge: ModelBridge
    @ObservedObject private var changes: ObservationBridge
    @FocusedValue(\.deviceModel) private var focused: AppModel?

    init(bridge: ModelBridge) {
        self.bridge = bridge
        _changes = ObservedObject(wrappedValue: bridge.changes)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Flash Image from File…") { focused?.chooseImageToFlash() }
                .keyboardShortcut("o")
                .disabled(focused == nil)
            Divider()
            Button("Show Flash Backups in Finder") { revealInFinder(FlashBackupStore.directory) }
            Button("Show Settings Backups in Finder") { revealInFinder(SnapshotStore.directory) }
        }

        CommandGroup(before: .toolbar) {
            ForEach(Array(AppModel.Section.allCases.enumerated()), id: \.element) { index, section in
                Button(section.rawValue) { focused?.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(focused == nil)
            }
            Divider()
        }

        CommandMenu("Device") {
            Menu("Connect") {
                if let model = focused {
                    if model.ports.isEmpty { Text("No USB serial devices found") }
                    ForEach(model.ports) { port in
                        Button("\(port.displayName) — \(port.hint)") { Task { await model.connect(port: port) } }
                    }
                    Divider()
                    if model.vendor == .meshcore {
                        Button("Demo Companion") { Task { await model.connectDemo(.companion) } }
                        Button("Demo Repeater") { Task { await model.connectDemo(.repeater) } }
                    } else {
                        Button("Demo Meshtastic") { Task { await model.connectDemo(.meshtastic) } }
                    }
                }
            }
            .disabled(focused == nil)
            Button("Disconnect") { focused?.disconnect() }
                .keyboardShortcut("d")
                .disabled(focused?.session == nil)
            Button("Refresh Devices") { focused?.refreshDevices() }
                .keyboardShortcut("r")
                .disabled(focused == nil)

            Divider()

            if focused?.vendor != .meshtastic {
                Button("Send Advert") { Task { await focused?.sendAdvert() } }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(focused?.canSendAdvert != true)
            }
            Button("Sync Clock") { Task { await focused?.syncClock() } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(focused?.canSendCommands != true)
            Button("Reboot Device") { Task { await focused?.rebootDevice() } }
                .disabled(focused?.canSendCommands != true)

            if let model = focused, model.vendor == .meshcore {
                Menu("Radio Preset") {
                    ForEach(model.presetsByRegion, id: \.region) { group in
                        Menu(group.region) {
                            ForEach(group.presets) { p in Button("\(p.title) — \(p.summary)") { model.stagePreset(p) } }
                        }
                    }
                    if !model.userPresets.isEmpty {
                        Divider()
                        Menu("My Presets") { ForEach(model.userPresets) { p in Button("\(p.title) — \(p.summary)") { model.stagePreset(p) } } }
                    }
                }
                .disabled(!model.canStagePreset)
            }

            Divider()

            Button("Read Settings from Device") { focused?.requestSettingsRefresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(focused?.canSendCommands != true)
            Button("Back Up Settings") { Task { await focused?.backUpConnectedDevice() } }
                .keyboardShortcut("b")
                .disabled(focused?.canSendCommands != true)
            Button("Show Protocol Log") { focused?.section = .log }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(focused == nil)
        }

        CommandMenu("Firmware") {
            if let model = focused {
                if model.vendor == .meshcore {
                    Picker("Role", selection: Binding(get: { model.firmware.role }, set: { model.firmware.role = $0 })) {
                        ForEach(MeshCoreRole.allCases) { Text($0.title).tag($0) }
                    }
                    if let group = model.firmware.selectedGroup, group.connections.count > 1 {
                        Picker("Connection", selection: Binding(get: { model.firmware.effectiveConnection(for: group) ?? .ble },
                                                                set: { model.firmware.preferredConnection = $0 })) {
                            ForEach(group.connections) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                    }
                } else {
                    Picker("Channel", selection: Binding(get: { model.firmware.channel }, set: { model.firmware.channel = $0 })) {
                        ForEach(MeshtasticChannel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Install Type", selection: Binding(get: { model.firmware.mtMode }, set: { model.firmware.mtMode = $0 })) {
                        ForEach(MeshtasticInstallMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Divider()
            }

            Button("Refresh Releases") { if let model = focused { Task { model.section = .firmware; await model.firmware.refresh() } } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(focused == nil)
            Button("Install Selected Board…") {
                guard let model = focused else { return }
                model.section = .firmware
                model.pendingFlash = model.vendor == .meshcore ? model.firmware.meshCoreRequest(model: model) : model.firmware.meshtasticRequest()
            }
            .keyboardShortcut("i")
            .disabled(installDisabled)
        }

        CommandGroup(replacing: .help) {
            Link("MeshCore Documentation", destination: URL(string: "https://docs.meshcore.io")!)
            Link("Meshtastic Documentation", destination: URL(string: "https://meshtastic.org/docs/")!)
            Divider()
            Link("MeshCore Firmware Releases", destination: URL(string: "https://github.com/meshcore-dev/MeshCore/releases")!)
            Link("Meshtastic Firmware Releases", destination: URL(string: "https://github.com/meshtastic/firmware/releases")!)
        }
    }

    private var installDisabled: Bool {
        guard let model = focused else { return true }
        return model.vendor == .meshcore ? model.firmware.selectedGroup == nil : model.firmware.mtSelectedBoard == nil
    }

    private func revealInFinder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 112, height: 112)
                Text("MeshKit").font(.system(size: 34, weight: .semibold))
                Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(FirmwareVendor.allCases) { vendor in
                    Button { openDeviceWindow(vendor, openWindow, dismissWindow) } label: {
                        WelcomeRow(title: vendor.rawValue, subtitle: vendor.tagline, symbol: vendor.symbol)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 48).padding(.bottom, 32).padding(.horizontal, 32)
        .frame(width: 460)
        .background(WindowPlacer())
        .task {
            if let launch = LaunchOptions.current { openDeviceWindow(launch.vendor, openWindow, dismissWindow) }
        }
    }
}

/// Centres the window on its screen, a little above the middle where the eye expects it.
private struct WindowPlacer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2,
                                          y: area.midY - window.frame.height / 2 + area.height * 0.08))
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct WelcomeRow: View {
    let title: String, subtitle: String, symbol: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.tint).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(hovering ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
    }
}

// MARK: - Settings

struct SettingsView: View {
    let workspace: Workspace
    @AppStorage("espBaud") private var baud = 460_800
    @AppStorage("espBackupFirst") private var backupFirst = true

    var body: some View {
        @Bindable var fw = workspace.meshtastic.firmware
        TabView {
            Form {
                Picker("Default speed", selection: $baud) {
                    Text("115,200 (slowest, most compatible)").tag(115_200)
                    Text("460,800").tag(460_800)
                    Text("921,600 (fastest)").tag(921_600)
                }
                Toggle("Back up the flash before installing", isOn: $backupFirst)
            }
            .formStyle(.grouped)
            .tabItem { Label("Flashing", systemImage: "bolt.horizontal") }

            Form {
                Toggle("Show community and unofficial Meshtastic boards", isOn: $fw.showCommunityBoards)
                Button("Clear Downloaded Firmware") { try? FileManager.default.removeItem(at: ReleaseClient.cacheDirectory) }
            }
            .formStyle(.grouped)
            .tabItem { Label("Firmware", systemImage: "square.and.arrow.down.on.square") }

            Form {
                Button("Show Flash Backups") { workspace.meshcore.revealInFinder(FlashBackupStore.directory) }
                Button("Show Settings Backups") { workspace.meshcore.revealInFinder(SnapshotStore.directory) }
            }
            .formStyle(.grouped)
            .tabItem { Label("Backups", systemImage: "externaldrive.badge.timemachine") }
        }
        .scenePadding()
        .frame(width: 480, height: 230)
    }
}

// MARK: - Main window

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.section ?? .firmware {
            case .firmware: FirmwareView()
            case .configure: ConfigureView()
            case .backups: BackupsView()
            case .log: LogView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.vendor.rawValue)
        .toolbar {
            ToolbarItem(placement: .navigation) { DeviceButton() }
            ToolbarItem(placement: .principal) { SectionTabs() }
        }
        .overlay(alignment: .bottom) {
            ActivityStatus()
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 16)
                .opacity(model.activity != nil || model.notice != nil ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: model.activity)
                .animation(.easeInOut(duration: 0.2), value: model.notice)
                .allowsHitTesting(false)
        }
        .focusedSceneValue(\.deviceModel, model)
        .task { await model.startPolling() }
        .task { await dumpMenuIfRequested() }
        .task { NSApp.activate(ignoringOtherApps: true) }
        // Closing the window lets go of the device, so the other app (or window) can use the port.
        .onDisappear { model.disconnect() }
        .sheet(item: $model.pendingFlash) { FlashSheet(request: $0) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.flashImage(at: url)
            return true
        }
    }
}

struct DeviceButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Button { model.showingDevices.toggle() } label: {
            if let session = model.session {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text(session.title).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                }
            } else {
                HStack(spacing: 6) {
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text("Disconnected")
                }
            }
        }
        .help(model.session == nil ? "Connect to a device" : "Devices")
        .popover(isPresented: $model.showingDevices, arrowEdge: .bottom) { DevicesView() }
    }
}

/// Toolbar tabs in the style of Safari's settings window.
struct SectionTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.Section.allCases) { section in
                let selected = (model.section ?? .firmware) == section
                Button { model.section = section } label: {
                    VStack(spacing: 2) {
                        Image(systemName: section == .firmware ? model.vendor.symbol : section.symbol).font(.system(size: 17)).frame(height: 22)
                        Text(section == .firmware ? model.vendor.rawValue : section.rawValue).font(.system(size: 11))
                    }
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 72, height: 44)
                    .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct ActivityStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let activity = model.activity {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(activity + "…").font(.callout) }
        } else if let notice = model.notice {
            Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(notice.isError ? Color.orange : Color.green)
                .lineLimit(1)
                .help(notice.text)
        }
    }
}
