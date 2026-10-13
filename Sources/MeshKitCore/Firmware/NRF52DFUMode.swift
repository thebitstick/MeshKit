import Foundation

/// Puts an nRF52 board into DFU mode whatever firmware it runs and whether or not that firmware answers.
public enum NRF52DFUMode {
    public enum Outcome: Equatable, Sendable {
        /// A Meshtastic node accepted the request and is restarting into its UF2 bootloader: the board's drive appears.
        case uf2Drive
        /// The board was restarted with the 1200-baud touch into serial DFU, which has no drive. Firmware goes in over
        /// serial ("Install over USB serial"). This works with MeshCore and with firmware that doesn't answer at all.
        case serialDFU
    }

    /// The "1200 baud touch": opening the port at 1200 baud and dropping DTR reboots an Adafruit nRF52 board into serial DFU.
    public static func touch(path: String) async throws {
        let port = try SerialPort(path: path, baud: 1200)
        try port.setLines(dtr: true, rts: false)
        try await Task.sleep(for: .milliseconds(150))
        try port.setLines(dtr: false, rts: false)
        try await Task.sleep(for: .milliseconds(250))
        port.close()
    }

    /// A Meshtastic node is asked to restart into the UF2 bootloader, which gives the more useful state (a drive that any
    /// UF2 install works with). Anything else, including a node that doesn't answer, gets the serial DFU touch.
    public static func enter(
        path: String,
        openPort: (@Sendable () throws -> ByteTransport)? = nil,
        touch touchPort: (@Sendable () async throws -> Void)? = nil,
        logger: (@Sendable (String) -> Void)? = nil
    ) async throws -> Outcome {
        let transport = try openPort?() ?? SerialPort(path: path)
        let mesh = MeshtasticClient(transport: transport, logger: logger)
        var outcome = Outcome.serialDFU
        if await mesh.probe(timeout: 4), (try? await mesh.connect(timeout: 25)) != nil {
            do {
                try await mesh.enterDFUMode()
                outcome = .uf2Drive
            } catch {
                logger?("Meshtastic node refused the DFU request (\(error.localizedDescription)); using the serial DFU touch")
            }
        }
        await mesh.stop()
        transport.close()
        if outcome == .serialDFU {
            if let touchPort { try await touchPort() } else { try await touch(path: path) }
        } else {
            try await Task.sleep(for: .milliseconds(500))
        }
        return outcome
    }
}
