import Foundation
import Testing
@testable import MeshKitCore

/// Runs against a real board. Set MESHKIT_HARDWARE_PORT to a serial port (for example /dev/cu.usbserial-0001) holding a
/// MeshCore repeater on a Heltec V3, and pick the step with MESHKIT_HARDWARE_STEP. Never runs otherwise.
@Suite(.serialized) struct HardwareTests {
    static var port: String? { ProcessInfo.processInfo.environment["MESHKIT_HARDWARE_PORT"] }
    static var step: String { ProcessInfo.processInfo.environment["MESHKIT_HARDWARE_STEP"] ?? "" }
    static var out: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MESHKIT_HARDWARE_OUT"] ?? NSTemporaryDirectory()) }

    static func repeater(_ path: String) async throws -> (RepeaterCLIClient, (version: String, board: String)) {
        let transport = try SerialPort(path: path)
        try await Task.sleep(for: .milliseconds(2500))
        let cli = RepeaterCLIClient(transport: transport, logger: { print("  log:", $0) })
        await cli.start()
        _ = try? await cli.run("", quiet: .milliseconds(150), timeout: .milliseconds(400))
        return (cli, try await cli.identify())
    }

    static func snapshot(_ cli: RepeaterCLIClient) async throws -> [String: String] {
        var values: [String: String] = [:]
        for (id, result) in try await cli.readAll(CLICatalog.backupable) { if case .value(let v) = result { values[id] = v } }
        return values
    }

    @Test func identifyAndReadSettings() async throws {
        guard let path = Self.port, Self.step == "read" else { return }
        let (cli, ident) = try await Self.repeater(path)
        print("IDENT", ident)
        let values = try await Self.snapshot(cli)
        for (k, v) in values.sorted(by: { $0.key < $1.key }) { print("SETTING \(k) = \(v)") }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: Self.out.appendingPathComponent("settings-before.json"))
        for extra in ["ver", "board", "clock", "neighbors"] {
            let r = try? await cli.run(extra)
            print("CMD \(extra) ->", r ?? "(no reply)")
        }
        await cli.stop()
    }

    @Test func rawReplies() async throws {
        guard let path = Self.port, Self.step == "raw" else { return }
        let transport = try SerialPort(path: path)
        try await Task.sleep(for: .milliseconds(2500))
        let stream = transport.subscribe()
        let collector = Task { var all = Data(); for await chunk in stream { all.append(chunk) }; return all }
        for cmd in ["get name", "get radio", "ver"] {
            try await transport.send(Data((cmd + "\r\n").utf8))
            try await Task.sleep(for: .milliseconds(700))
        }
        transport.close()
        let data = await collector.value
        print("RAW", data.map { String(format: "%02x", $0) }.joined(), String(decoding: data, as: UTF8.self).debugDescription)
    }

    @Test func writeAndRestoreSettings() async throws {
        guard let path = Self.port, Self.step == "write" else { return }
        let (cli, _) = try await Self.repeater(path)
        let before = try await Self.snapshot(cli)
        let name = try #require(CLICatalog.setting("name"))
        let original = try #require(before["name"])
        let reply = try await cli.write(name, value: "MeshKit Test")
        print("SET name ->", reply.debugDescription)
        print("READBACK", try await cli.read(name))
        let restored = try await cli.write(name, value: original)
        print("RESTORE ->", restored.debugDescription)
        print("READBACK", try await cli.read(name))
        let after = try await Self.snapshot(cli)
        #expect(after == before)
        print("CLOCK SYNC ->", try await cli.run("time \(Int(Date().timeIntervalSince1970))").debugDescription)
        print("CLOCK ->", try await cli.run("clock").debugDescription)
        print("ADVERT ->", try await cli.run("advert").debugDescription)
        await cli.stop()
    }

    static func mergedRepeaterImage() async throws -> (data: Data, name: String) {
        let client = ReleaseClient()
        let release = try #require(try await client.releases(for: .repeater, limit: 1).first)
        let builds = ReleaseClient.builds(from: release, role: .repeater)
        let build = try #require(builds.first { $0.board == "Heltec_v3" })
        let artifact = try #require(build.artifacts.first { $0.kind == .espFullImage })
        let url = try await client.download(artifact)
        return (try Data(contentsOf: url), artifact.asset.name)
    }

    static func flash(_ job: ESPFlashJob, path: String, backup: Bool = true) async throws {
        let flasher = ESPFlasher(portPath: path, job: job, options: ESPFlashOptions(baudRate: 460_800, useStub: true, backupFirst: backup),
                                 logger: { print("  esp:", $0) })
        print("STEPS", flasher.steps.map(\.title))
        try await flasher.run { id, state in
            switch state {
            case .running(let p?): if Int(p * 100) % 25 == 0 { print("  step \(id): \(Int(p * 100))%") }
            case .running: print("  step \(id): running")
            case .done: print("  step \(id): done")
            case .failed(let m): print("  step \(id): FAILED \(m)")
            case .pending: break
            }
        }
    }

    @Test func updateKeepsSettings() async throws {
        guard let path = Self.port, Self.step == "update" else { return }
        let (merged, name) = try await Self.mergedRepeaterImage()
        print("IMAGE", name, merged.count)
        try await Self.flash(MeshCoreImage.updateJob(merged: merged, name: name), path: path)
        try await Task.sleep(for: .seconds(3))
        let (cli, ident) = try await Self.repeater(path)
        print("AFTER IDENT", ident)
        let after = try await Self.snapshot(cli)
        let beforeData = try Data(contentsOf: Self.out.appendingPathComponent("settings-before.json"))
        let before = try JSONSerialization.jsonObject(with: beforeData) as? [String: String] ?? [:]
        for (k, v) in before where after[k] != v { print("DIFF \(k): \(v) -> \(after[k] ?? "nil")") }
        #expect(after == before)
        await cli.stop()
    }

    @Test func cleanInstall() async throws {
        guard let path = Self.port, Self.step == "clean" else { return }
        let (merged, name) = try await Self.mergedRepeaterImage()
        try await Self.flash(MeshCoreImage.cleanJob(merged: merged, name: name), path: path)
        try await Task.sleep(for: .seconds(4))
        let (cli, ident) = try await Self.repeater(path)
        print("AFTER IDENT", ident)
        let after = try await Self.snapshot(cli)
        for (k, v) in after.sorted(by: { $0.key < $1.key }) { print("FRESH \(k) = \(v)") }
        await cli.stop()
    }

    @Test func restoreNewestBackupBefore() async throws {
        guard let path = Self.port, Self.step.hasPrefix("restore:") else { return }
        let file = String(Self.step.dropFirst("restore:".count))
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        print("RESTORING", file, data.count)
        try await Self.flash(.single(data, name: "backup"), path: path, backup: false)
        try await Task.sleep(for: .seconds(4))
        let (cli, ident) = try await Self.repeater(path)
        print("AFTER IDENT", ident)
        let after = try await Self.snapshot(cli)
        let beforeData = try Data(contentsOf: Self.out.appendingPathComponent("settings-before.json"))
        let before = try JSONSerialization.jsonObject(with: beforeData) as? [String: String] ?? [:]
        for (k, v) in before where after[k] != v { print("DIFF \(k): \(v) -> \(after[k] ?? "nil")") }
        #expect(after == before)
        await cli.stop()
    }

    @Test func setValue() async throws {
        guard let path = Self.port, Self.step.hasPrefix("set:") else { return }
        let parts = Self.step.dropFirst(4).split(separator: "=", maxSplits: 1).map(String.init)
        let (cli, _) = try await Self.repeater(path)
        let setting = try #require(CLICatalog.setting(parts[0]))
        print("SET ->", try await cli.write(setting, value: parts[1]))
        print("NOW", try await cli.read(setting))
        await cli.stop()
    }

    @Test func catalogAgainstTheDevice() async throws {
        guard let path = Self.port, Self.step == "catalog" else { return }
        let (cli, _) = try await Self.repeater(path)
        let before = try await Self.snapshot(cli)
        let skip: Set<String> = ["radio", "name", "lat", "lon", "owner.info"]
        for setting in CLICatalog.backupable where !skip.contains(setting.id) {
            guard let current = before[setting.id] else { print("MISSING", setting.id); continue }
            var tries: [(String, Bool)] = [(current.replacingOccurrences(of: "%", with: ""), true)]
            switch setting.kind {
            case .number(let r):
                tries += [(String(r.lowerBound), true), (String(r.upperBound), true), (String(r.lowerBound - 1), false), (String(r.upperBound + 1), false)]
            case .onOff: tries += [("on", true), ("off", true)]
            case .choice(let options): tries += options.map { ($0, true) }
            default: break
            }
            for (value, shouldWork) in tries {
                let reply = try await cli.write(setting, value: value)
                let worked = !reply.lowercased().hasPrefix("err") && reply.hasPrefix("OK")
                if worked != shouldWork { print("MISMATCH \(setting.id) = \(value): expected \(shouldWork ? "OK" : "error"), got \(reply.debugDescription)") }
            }
            let restore = try await cli.write(setting, value: current.replacingOccurrences(of: "%", with: ""))
            print("CHECKED \(setting.id) restore ->", restore)
        }
        let after = try await Self.snapshot(cli)
        for (k, v) in before where after[k] != v { print("LEFT-DIFF \(k): \(v) -> \(after[k] ?? "nil")") }
        await cli.stop()
    }
}
