import Foundation
import Testing
@testable import MeshKitCore

/// The simulated console behaves like a real v1.17.1 repeater: `get` answers `-> > value`, a `set` is echoed at once and
/// answered `OK` half a second later, and `clock sync` fails over serial while `time <epoch>` works.
@Suite struct RepeaterConsoleTests {
    private func client() async -> RepeaterCLIClient {
        let cli = RepeaterCLIClient(transport: SimulatedRepeaterTransport())
        await cli.start()
        return cli
    }

    @Test func readsValuesWithoutThePrompt() async throws {
        let cli = await client()
        let name = try #require(CLICatalog.setting("name"))
        guard case .value(let v) = try await cli.read(name) else { Issue.record("no value"); return }
        #expect(!v.hasPrefix(">") && !v.isEmpty)
        await cli.stop()
    }

    @Test func aSlowSetIsAnsweredBeforeTheNextCommand() async throws {
        let cli = await client()
        let name = try #require(CLICatalog.setting("name"))
        #expect(try await cli.write(name, value: "Hilltop") == "OK")
        #expect(try await cli.read(name) == .value("Hilltop"))
        await cli.stop()
    }

    @Test func clockSyncUsesTimeAndErrorsAreThrown() async throws {
        let cli = await client()
        await #expect(throws: RepeaterCLIClient.DeviceError.self) { try await cli.runChecked("clock sync") }
        let reply = try await cli.runChecked("time \(Int(Date().timeIntervalSince1970))")
        #expect(reply.hasPrefix("OK"))
        #expect(CLICommand.quickActions.first { $0.id == "clocksync" }?.resolvedCommand.hasPrefix("time ") == true)
        await cli.stop()
    }
}
