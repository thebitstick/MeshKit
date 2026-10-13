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

public struct UF2VolumeFlasher: Flasher {
    public let volume: UF2Volume
    public let image: Data
    public init(volume: UF2Volume, image: Data) { self.volume = volume; self.image = image }

    public var steps: [FlashStep] {
        [.init(id: "verify", title: "Check UF2 image"),
         .init(id: "write", title: "Copy to \(volume.name)"),
         .init(id: "reboot", title: "Wait for the board to reboot")]
    }

    public func run(update: @escaping @Sendable (String, FlashStep.State) -> Void) async throws {
        update("verify", .running(nil))
        let info = try UF2.inspect(image)
        guard info.isNRF52 else {
            let msg = "Image targets \(info.familyName), not nRF52"
            update("verify", .failed(msg))
            throw UF2Error.writeFailed(msg)
        }
        update("verify", .done)

        update("write", .running(0))
        let outcome = try await UF2Flasher.flash(image: image, to: volume) { update("write", .running($0)) }
        update("write", .done)

        update("reboot", .running(nil))
        switch outcome {
        case .rebooted: update("reboot", .done)
        case .volumeStillMounted: update("reboot", .failed("Board is still in bootloader mode; check the board and replug if needed"))
        }
    }
}
