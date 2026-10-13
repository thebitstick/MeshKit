import Foundation

public struct FlashStep: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case pending, running(Double?), done, failed(String) }
    public let id: String
    public let title: String
    public var state: State = .pending

    public init(id: String, title: String, state: State = .pending) {
        self.id = id; self.title = title; self.state = state
    }
}

public enum FlashTarget: Sendable {
    case uf2Volume(UF2Volume)
    case serialPort(SerialPortInfo)

    public var label: String {
        switch self {
        case .uf2Volume(let v): "\(v.name) (UF2 bootloader)"
        case .serialPort(let p): p.displayName
        }
    }
}

public protocol Flasher: Sendable {
    var steps: [FlashStep] { get }
    func run(update: @escaping @Sendable (_ stepID: String, _ state: FlashStep.State) -> Void) async throws
}

/// Meshtastic's "factory erase" UF2 files, which wipe an Adafruit-bootloader nRF52 board (application, settings and
/// filesystem) and drop it back into the bootloader. There is one per SoftDevice generation; the bootloader's
/// `INFO_UF2.TXT` says which one a board has.
public struct NRF52EraseImages: Sendable {
    public let images: [String: Data]

    public init(images: [String: Data]) { self.images = images }

    static let fileNames = ["7.3": "Meshtastic_nRF52_factory_erase_v3_S140_7.3.0.uf2", "6.1": "Meshtastic_nRF52_factory_erase_v3_S140_6.1.0.uf2"]

    /// "S140 7.3.0" -> "7.3"
    static func series(ofSoftDevice text: String) -> String? {
        text.firstMatch(of: #/(\d+)\.(\d+)\.\d+/#).map { "\($0.1).\($0.2)" }
    }

    public func image(for volume: UF2Volume) -> Data? {
        Self.series(ofSoftDevice: volume.softDevice).flatMap { images[$0] }
    }
}

public struct UF2VolumeFlasher: Flasher {
    public let volume: UF2Volume
    public let image: Data
    public let erase: NRF52EraseImages?
    private let findVolumes: @Sendable () -> [UF2Volume]
    private let returnTimeout: Duration

    public init(volume: UF2Volume, image: Data, erase: NRF52EraseImages? = nil,
                findVolumes: @escaping @Sendable () -> [UF2Volume] = { UF2Volumes.detect() },
                returnTimeout: Duration = .seconds(60)) {
        self.volume = volume; self.image = image; self.erase = erase
        self.findVolumes = findVolumes; self.returnTimeout = returnTimeout
    }

    public var steps: [FlashStep] {
        var s: [FlashStep] = [.init(id: "verify", title: "Check UF2 image")]
        if erase != nil {
            s += [.init(id: "erase", title: "Erase the board"), .init(id: "return", title: "Wait for the bootloader drive to return")]
        }
        s += [.init(id: "write", title: "Copy to \(volume.name)"), .init(id: "reboot", title: "Wait for the board to reboot")]
        return s
    }

    public func run(update: @escaping @Sendable (String, FlashStep.State) -> Void) async throws {
        update("verify", .running(nil))
        let info = try UF2.inspect(image)
        guard info.isNRF52 else {
            let msg = "Image targets \(info.familyName), not nRF52"
            update("verify", .failed(msg))
            throw UF2Error.writeFailed(msg)
        }
        var eraseImage: Data?
        if let erase {
            guard let found = erase.image(for: volume) else {
                let msg = "This bootloader reports SoftDevice \"\(volume.softDevice)\", and no matching erase file is available."
                update("verify", .failed(msg))
                throw UF2Error.writeFailed(msg)
            }
            _ = try UF2.inspect(found)
            eraseImage = found
        }
        update("verify", .done)

        var target = volume
        if let eraseImage {
            update("erase", .running(0))
            let erased = try await UF2Flasher.flash(image: eraseImage, to: volume) { update("erase", .running($0)) }
            guard erased == .rebooted else {
                let msg = "The board did not run the erase file; it is still in bootloader mode."
                update("erase", .failed(msg))
                throw UF2Error.writeFailed(msg)
            }
            update("erase", .done)

            update("return", .running(nil))
            guard let back = try await waitForBootloader(like: volume) else {
                let msg = "The board erased itself but did not come back as a bootloader drive. Double-tap reset, then install again."
                update("return", .failed(msg))
                throw UF2Error.writeFailed(msg)
            }
            target = back
            update("return", .done)
        }

        update("write", .running(0))
        let outcome = try await UF2Flasher.flash(image: image, to: target) { update("write", .running($0)) }
        update("write", .done)

        update("reboot", .running(nil))
        switch outcome {
        case .rebooted: update("reboot", .done)
        case .volumeStillMounted: update("reboot", .failed("Board is still in bootloader mode; check the board and replug if needed"))
        }
    }

    private func waitForBootloader(like old: UF2Volume) async throws -> UF2Volume? {
        let deadline = ContinuousClock.now + returnTimeout
        while ContinuousClock.now < deadline {
            if let back = findVolumes().first(where: { $0.boardID == old.boardID && $0.model == old.model }) { return back }
            try await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }
}
