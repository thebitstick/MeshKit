import AppKit
import Sparkle

@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    private override init() {
        // Without an app bundle (`swift run`) there is no feed to read, so the updater stays off.
        controller = SPUStandardUpdaterController(startingUpdater: Bundle.main.bundleIdentifier != nil && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
