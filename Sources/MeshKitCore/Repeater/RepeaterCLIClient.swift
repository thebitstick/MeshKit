import Foundation

/// Text console client for repeater / room-server firmware over USB serial.
///
/// The firmware echoes typed characters and answers with a line prefixed by `->` (older
/// builds) or `>`. Both are stripped. Lines are terminated with CRLF, which is accepted
/// whether the firmware keys on CR or LF. A reply is considered complete once the port has
/// been quiet for `quiet`, since the protocol has no end-of-reply marker.
public actor RepeaterCLIClient {
    private let transport: ByteTransport
    private var buffer = ""
    private var lastReceive = ContinuousClock.now
    private var readTask: Task<Void, Never>?
    private var busy = false
    private var turnQueue: [CheckedContinuation<Void, Never>] = []
    public nonisolated let logger: (@Sendable (String) -> Void)?

    public init(transport: ByteTransport, logger: (@Sendable (String) -> Void)? = nil) {
        self.transport = transport
        self.logger = logger
    }

    public func start() {
        guard readTask == nil else { return }
        let stream = transport.subscribe()
        readTask = Task { [weak self] in
            for await chunk in stream { await self?.ingest(chunk) }
        }
    }

    public func stop() {
        readTask?.cancel()
        readTask = nil
    }

    private func ingest(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        lastReceive = .now
    }

    private func acquire() async {
        if busy { await withCheckedContinuation { turnQueue.append($0) } } else { busy = true }
    }

    private func release() {
        if turnQueue.isEmpty { busy = false } else { turnQueue.removeFirst().resume() }
    }

    @discardableResult
    public func run(_ command: String, quiet: Duration = .milliseconds(350), timeout: Duration = .seconds(3)) async throws -> String {
        try await exchange(command, quiet: quiet, timeout: timeout).text
    }

    public func exchange(_ command: String, quiet: Duration = .milliseconds(350), timeout: Duration = .seconds(3)) async throws -> (text: String, heardAnything: Bool) {
        await acquire()
        defer { release() }
        buffer = ""
        logger?("→ \(command)")
        try await transport.send(Data((command + "\r\n").utf8))

        let start = ContinuousClock.now
        while true {
            try await Task.sleep(for: .milliseconds(40))
            let now = ContinuousClock.now
            if Self.hasReply(buffer, to: command) && now - lastReceive >= quiet { break }
            if now - start >= timeout { break }
        }
        let reply = Self.clean(buffer, command: command)
        logger?("← \(reply)")
        return (reply, !buffer.isEmpty)
    }

    /// The firmware echoes a command straight away but can take a second to answer one that writes to flash, so an echo
    /// alone doesn't mean the reply is complete.
    static func hasReply(_ raw: String, to command: String) -> Bool {
        raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .contains { $0.trimmingCharacters(in: .whitespaces) != command }
    }

    static func clean(_ raw: String, command: String) -> String {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == command { lines.removeFirst() }
        return lines.map { line in
            var l = Substring(line)
            while l.first == " " { l = l.dropFirst() }
            if l.hasPrefix("->") {
                l = l.dropFirst(2)
                while l.first == " " { l = l.dropFirst() }
                if l == ">" { l = "" } else if l.hasPrefix("> ") { l = l.dropFirst(2) }
            } else if l.hasPrefix(">") { l = l.dropFirst(1) }
            while l.first == " " { l = l.dropFirst() }
            return String(l)
        }.joined(separator: "\n")
    }

    // MARK: Settings

    public enum ReadResult: Equatable, Sendable {
        case value(String)
        case unsupported
    }

    public func read(_ setting: CLISetting) async throws -> ReadResult {
        let (reply, heard) = try await exchange(setting.getCommand, quiet: .milliseconds(250), timeout: .seconds(1.5))
        let lower = reply.lowercased()
        if !heard || lower.hasPrefix("err") || lower.contains("unknown") || lower.contains("not supported") {
            return .unsupported
        }
        return .value(reply)
    }

    public func write(_ setting: CLISetting, value: String) async throws -> String {
        try await run(setting.setCommand(value), quiet: .milliseconds(250), timeout: .seconds(4))
    }

    public struct DeviceError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Runs a command and throws if the device answers with an error such as `ERR: clock cannot go backwards`.
    @discardableResult
    public func runChecked(_ command: String, timeout: Duration = .seconds(3)) async throws -> String {
        let reply = try await run(command, timeout: timeout)
        if reply.hasPrefix("ERR") { throw DeviceError(message: reply) }
        return reply
    }

    public func readAll(_ settings: [CLISetting], progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [String: ReadResult] {
        var out: [String: ReadResult] = [:]
        for (i, s) in settings.enumerated() {
            out[s.id] = try await read(s)
            progress?(i + 1, settings.count)
        }
        return out
    }

    public func identify() async throws -> (version: String, board: String) {
        let v = try await run("ver", quiet: .milliseconds(300), timeout: .seconds(1.5))
        let b = try await run("board", quiet: .milliseconds(300), timeout: .seconds(1.5))
        return (v, b)
    }
}
