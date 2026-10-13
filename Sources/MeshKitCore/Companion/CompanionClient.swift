import Foundation

public enum CompanionError: Error, LocalizedError, Equatable {
    case timeout
    case deviceError(UInt8?)
    case unexpected(String)
    case transportClosed

    public var errorDescription: String? {
        switch self {
        case .timeout: "The device did not answer in time"
        case .deviceError(let code):
            "The device rejected the command" + (code.map { " (\(Self.name(for: $0)))" } ?? "")
        case .unexpected(let s): "Unexpected reply: \(s)"
        case .transportClosed: "The connection was closed"
        }
    }

    static func name(for code: UInt8) -> String {
        switch code {
        case 1: "unsupported command"
        case 2: "not found"
        case 3: "table full"
        case 4: "bad state"
        case 5: "file I/O error"
        case 6: "illegal argument"
        default: "error \(code)"
        }
    }
}

public actor CompanionClient {
    private struct Pending {
        let id: UInt64
        let continuation: CheckedContinuation<[CompanionResponse], Error>
        let isDone: @Sendable (CompanionResponse) -> Bool
        var collected: [CompanionResponse] = []
        var timeout: Task<Void, Never>?
    }

    private let transport: ByteTransport
    private var decoder = FrameDecoder()
    private var pending: Pending?
    private var nextID: UInt64 = 0
    private var busy = false
    private var turnQueue: [CheckedContinuation<Void, Never>] = []
    private var readTask: Task<Void, Never>?
    private let pushSink: AsyncStream<CompanionResponse>.Continuation

    public nonisolated let pushes: AsyncStream<CompanionResponse>
    public nonisolated let logger: (@Sendable (String) -> Void)?

    public init(transport: ByteTransport, logger: (@Sendable (String) -> Void)? = nil) {
        self.transport = transport
        self.logger = logger
        var sink: AsyncStream<CompanionResponse>.Continuation!
        pushes = AsyncStream { sink = $0 }
        pushSink = sink
    }

    public func start() {
        guard readTask == nil else { return }
        let stream = transport.subscribe()
        readTask = Task { [weak self] in
            for await chunk in stream { await self?.ingest(chunk) }
            await self?.streamEnded()
        }
    }

    public func stop() {
        readTask?.cancel()
        readTask = nil
        failPending(CompanionError.transportClosed)
        pushSink.finish()
    }

    // MARK: Plumbing

    private func ingest(_ data: Data) {
        for frame in decoder.feed(data) {
            logger?("← " + frame.hexString)
            let response: CompanionResponse
            do { response = try CompanionResponse.parse(frame) } catch {
                logger?("! \(error.localizedDescription)")
                failPending(error)
                continue
            }
            if response.isPush { pushSink.yield(response); continue }
            guard var p = pending else { continue }
            p.collected.append(response)
            if p.isDone(response) {
                pending = nil
                p.timeout?.cancel()
                p.continuation.resume(returning: p.collected)
            } else {
                pending = p
            }
        }
    }

    private func streamEnded() { failPending(CompanionError.transportClosed) }

    private func failPending(_ error: Error, id: UInt64? = nil) {
        guard let p = pending, id == nil || p.id == id else { return }
        pending = nil
        p.timeout?.cancel()
        p.continuation.resume(throwing: error)
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { turnQueue.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if turnQueue.isEmpty { busy = false } else { turnQueue.removeFirst().resume() }
    }

    public func request(
        _ payload: [UInt8],
        timeout: Duration = .seconds(3),
        until isDone: @escaping @Sendable (CompanionResponse) -> Bool
    ) async throws -> [CompanionResponse] {
        await acquire()
        defer { release() }
        nextID += 1
        let id = nextID
        logger?("→ " + payload.hexString)
        let frame = USBFrame.encode(payload)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[CompanionResponse], Error>) in
            let timer = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self.failPending(CompanionError.timeout, id: id)
            }
            pending = Pending(id: id, continuation: cont, isDone: isDone, timeout: timer)
            Task { [transport] in
                do { try await transport.send(frame) } catch { self.failPending(error, id: id) }
            }
        }
    }

    private static let isOKOrErr: @Sendable (CompanionResponse) -> Bool = { r in
        switch r {
        case .ok, .err: true
        default: false
        }
    }

    private func command(_ payload: [UInt8], timeout: Duration = .seconds(3)) async throws {
        let replies = try await request(payload, timeout: timeout, until: Self.isOKOrErr)
        if case .err(let code) = replies.last { throw CompanionError.deviceError(code) }
    }

    // MARK: High-level operations

    public func handshake() async throws -> (DeviceInfo, SelfInfo) {
        let q = try await request(CompanionRequest.deviceQuery(), timeout: .seconds(2)) {
            if case .deviceInfo = $0 { true } else if case .err = $0 { true } else { false }
        }
        guard case .deviceInfo(let info)? = q.last else { throw CompanionError.unexpected("device query") }

        let s = try await request(CompanionRequest.appStart(), timeout: .seconds(2)) {
            if case .selfInfo = $0 { true } else if case .err = $0 { true } else { false }
        }
        guard case .selfInfo(let me)? = s.last else { throw CompanionError.unexpected("app start") }
        return (info, me)
    }

    public func contacts() async throws -> [Contact] {
        let replies = try await request(CompanionRequest.getContacts(), timeout: .seconds(10)) {
            if case .endOfContacts = $0 { true } else if case .err = $0 { true } else { false }
        }
        if case .err(let c)? = replies.last { throw CompanionError.deviceError(c) }
        return replies.compactMap { if case .contact(let c) = $0 { c } else { nil } }
    }

    public func battery() async throws -> BatteryInfo {
        let r = try await request(CompanionRequest.getBatteryAndStorage) {
            if case .battery = $0 { true } else if case .err = $0 { true } else { false }
        }
        guard case .battery(let b)? = r.last else { throw CompanionError.unexpected("battery") }
        return b
    }

    public func stats(_ subType: UInt8) async throws -> RadioStats {
        let r = try await request(CompanionRequest.getStats(subType: subType)) {
            if case .stats = $0 { true } else if case .err = $0 { true } else { false }
        }
        if case .err(let c)? = r.last { throw CompanionError.deviceError(c) }
        guard case .stats(let s)? = r.last else { throw CompanionError.unexpected("stats") }
        return s
    }

    public func deviceTime() async throws -> Date {
        let r = try await request(CompanionRequest.getDeviceTime) {
            if case .currentTime = $0 { true } else if case .err = $0 { true } else { false }
        }
        guard case .currentTime(let t)? = r.last else { throw CompanionError.unexpected("time") }
        return Date(timeIntervalSince1970: TimeInterval(t))
    }

    public func syncClock() async throws { try await command(CompanionRequest.setDeviceTime(UInt32(Date().timeIntervalSince1970))) }
    public func sendAdvert(flood: Bool) async throws { try await command(CompanionRequest.sendSelfAdvert(flood: flood)) }
    public func setName(_ name: String) async throws { try await command(CompanionRequest.setAdvertName(name)) }
    public func setTxPower(_ dBm: Int) async throws { try await command(CompanionRequest.setTxPower(dBm)) }
    public func setLocation(latitude: Double, longitude: Double) async throws {
        try await command(CompanionRequest.setAdvertLatLon(latitude: latitude, longitude: longitude))
    }
    public func setRadio(frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: Int, codingRate: Int) async throws {
        try await command(CompanionRequest.setRadioParams(frequencyMHz: frequencyMHz, bandwidthKHz: bandwidthKHz,
                                                          spreadingFactor: spreadingFactor, codingRate: codingRate))
    }

    /// The device may reset before answering, so a timeout is treated as success.
    public func reboot() async throws {
        do { try await command(CompanionRequest.reboot, timeout: .seconds(1)) } catch CompanionError.timeout {}
    }
}
