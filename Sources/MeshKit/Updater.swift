import AppKit
import Sparkle

@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    private override init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    /// Started a moment after launch so that Sparkle's first-run question opens in front of the Welcome window, not behind
    /// it. Without an app bundle (`swift run`) there is no feed to read, so the updater stays off.
    func startSoon() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in controller.startUpdater() }
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastChecked: Date? { controller.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
