import Foundation
import MeshtasticProtobufs
import SwiftProtobuf

/// Framing for Meshtastic's stream API (USB serial and TCP): `0x94 0xC3`, a big-endian 16-bit length, then a
/// protobuf. Anything else on the wire (the firmware prints log lines on the same port) is skipped.
public enum MeshtasticStream {
    public static let start1: UInt8 = 0x94
    public static let start2: UInt8 = 0xC3
    public static let maxPayload = 512

    public static func frame(_ payload: [UInt8]) -> Data {
        var out: [UInt8] = [start1, start2, UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)]
        out += payload
        return Data(out)
    }
}

public struct MeshtasticFrameDecoder {
    private enum State { case start1, start2, lengthHigh, lengthLow, payload }
    private var state = State.start1
    private var high = 0
    private var length = 0
    private var payload: [UInt8] = []
    public private(set) var discardedBytes = 0

    public init() {}

    public mutating func feed(_ data: Data) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for b in data {
            switch state {
            case .start1:
                if b == MeshtasticStream.start1 { state = .start2 } else { discardedBytes += 1 }
            case .start2:
                if b == MeshtasticStream.start2 { state = .lengthHigh }
                else if b == MeshtasticStream.start1 { discardedBytes += 1 }       // a run of 0x94 stays armed
                else { discardedBytes += 2; state = .start1 }
            case .lengthHigh:
                high = Int(b); state = .lengthLow
            case .lengthLow:
                length = high << 8 | Int(b)
                if length == 0 || length > MeshtasticStream.maxPayload { discardedBytes += 4; state = .start1 }
                else { payload = []; payload.reserveCapacity(length); state = .payload }
            case .payload:
                payload.append(b)
                if payload.count == length { frames.append(payload); state = .start1 }
            }
        }
        return frames
    }
}

public enum MeshtasticNodeError: Error, LocalizedError, Equatable {
    case timeout(String)
    case notMeshtastic
    case rejected(String)
    case notConnected
    case managed

    public var errorDescription: String? {
        switch self {
        case .timeout(let w): "The node didn't answer in time (\(w))"
        case .notMeshtastic: "That device didn't answer like a Meshtastic node"
        case .rejected(let r): "The node rejected the change (\(r))"
        case .notConnected: "Not connected to a node"
        case .managed: "This node is managed by a remote administrator and ignores changes made from here"
        }
    }
}

public struct MeshtasticNodeState: Sendable {
    public var myInfo: MyNodeInfo?
    public var metadata: DeviceMetadata?
    public var device: Config.DeviceConfig?
    public var position: Config.PositionConfig?
    public var power: Config.PowerConfig?
    public var network: Config.NetworkConfig?
    public var display: Config.DisplayConfig?
    public var lora: Config.LoRaConfig?
    public var bluetooth: Config.BluetoothConfig?
    public var security: Config.SecurityConfig?
    public var channels: [Channel] = []
    public var nodes: [NodeInfo] = []

    public init() {}

    public var myNodeNum: UInt32 { myInfo?.myNodeNum ?? 0 }
    public var nodeID: String { String(format: "!%08x", myNodeNum) }
    public var owner: User? { nodes.first { $0.num == myNodeNum }?.user }
}

public struct MeshtasticEdit: Sendable {
    public var longName: String?
    public var shortName: String?
    public var lora: Config.LoRaConfig?
    public var device: Config.DeviceConfig?
    public init(longName: String? = nil, shortName: String? = nil, lora: Config.LoRaConfig? = nil, device: Config.DeviceConfig? = nil) {
        self.longName = longName; self.shortName = shortName; self.lora = lora; self.device = device
    }
    public var isEmpty: Bool { longName == nil && shortName == nil && lora == nil && device == nil }
}

public actor MeshtasticClient {
    private let transport: ByteTransport
    private var decoder = MeshtasticFrameDecoder()
    private var queue: [FromRadio] = []
    private var waiter: (id: UInt64, cont: CheckedContinuation<FromRadio, Error>, timeout: Task<Void, Never>?)?
    private var nextWaiterID: UInt64 = 0
    private var readTask: Task<Void, Never>?
    private var sessionPasskey = Data()
    public private(set) var state = MeshtasticNodeState()
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
        failWaiter(MeshtasticNodeError.notConnected)
    }

    // MARK: Plumbing

    private func ingest(_ data: Data) {
        for payload in decoder.feed(data) {
            guard let message = try? FromRadio(serializedBytes: payload) else { logger?("! undecodable FromRadio"); continue }
            if let w = waiter { waiter = nil; w.timeout?.cancel(); w.cont.resume(returning: message) } else { queue.append(message) }
        }
    }

    private func failWaiter(_ error: Error, id: UInt64? = nil) {
        guard let w = waiter, id == nil || w.id == id else { return }
        waiter = nil
        w.timeout?.cancel()
        w.cont.resume(throwing: error)
    }

    private func next(timeout: Double, what: String) async throws -> FromRadio {
        if !queue.isEmpty { return queue.removeFirst() }
        nextWaiterID += 1
        let id = nextWaiterID
        return try await withCheckedThrowingContinuation { cont in
            let timer = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self.failWaiter(MeshtasticNodeError.timeout(what), id: id)
            }
            waiter = (id, cont, timer)
        }
    }

    private func send(_ message: ToRadio) async throws {
        let bytes = [UInt8](try message.serializedData())
        try await transport.send(MeshtasticStream.frame(bytes))
    }

    private func absorb(_ frame: FromRadio) {
        switch frame.payloadVariant {
        case .myInfo(let v): state.myInfo = v
        case .metadata(let v): state.metadata = v
        case .nodeInfo(let v):
            if let i = state.nodes.firstIndex(where: { $0.num == v.num }) { state.nodes[i] = v } else { state.nodes.append(v) }
        case .config(let c):
            switch c.payloadVariant {
            case .device(let v): state.device = v
            case .position(let v): state.position = v
            case .power(let v): state.power = v
            case .network(let v): state.network = v
            case .display(let v): state.display = v
            case .lora(let v): state.lora = v
            case .bluetooth(let v): state.bluetooth = v
            case .security(let v): state.security = v
            default: break
            }
        case .channel(let c):
            if let i = state.channels.firstIndex(where: { $0.index == c.index }) { state.channels[i] = c } else { state.channels.append(c) }
            state.channels.sort { $0.index < $1.index }
        case .packet(let p):
            if case .decoded(let d)? = p.payloadVariant, d.portnum == .adminApp,
               let admin = try? AdminMessage(serializedBytes: [UInt8](d.payload)), !admin.sessionPasskey.isEmpty {
                sessionPasskey = admin.sessionPasskey
            }
        default: break
        }
    }

    private func wake() async throws {
        // Enough start bytes to make a sleeping or half-synchronised node look for a fresh frame (the node ignores them).
        try await transport.send(Data(repeating: MeshtasticStream.start2, count: 32))
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: Connecting

    public func probe(timeout: Double = 2.5) async -> Bool {
        start()
        queue.removeAll(); decoder = MeshtasticFrameDecoder()
        do {
            try await wake()
            try await send(ToRadio.with { $0.wantConfigID = UInt32.random(in: 1...0x7FFF_FFFF) })
            _ = try await next(timeout: timeout, what: "first frame")
            return true
        } catch { return false }
    }

    @discardableResult
    public func connect(timeout: Double = 25) async throws -> MeshtasticNodeState {
        start()
        state = MeshtasticNodeState()
        queue.removeAll(); decoder = MeshtasticFrameDecoder()
        try await wake()
        let id = UInt32.random(in: 1...0x7FFF_FFFF)
        try await send(ToRadio.with { $0.wantConfigID = id })

        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            let remaining = max(0.1, Double((deadline - .now).components.seconds))
            let frame: FromRadio
            do { frame = try await next(timeout: remaining, what: "configuration") } catch let e as MeshtasticNodeError {
                throw state.myInfo == nil ? MeshtasticNodeError.notMeshtastic : e
            }
            absorb(frame)
            if case .configCompleteID(let c)? = frame.payloadVariant, c == id { break }
        }
        guard state.myInfo != nil else { throw MeshtasticNodeError.notMeshtastic }
        logger?("connected to \(state.nodeID)")
        return state
    }

    // MARK: Admin

    private func newPacketID() -> UInt32 { UInt32.random(in: 1...0x7FFF_FFFF) }

    @discardableResult
    private func sendAdmin(wantResponse: Bool = true, _ build: (inout AdminMessage) -> Void) async throws -> UInt32 {
        guard state.myInfo != nil else { throw MeshtasticNodeError.notConnected }
        var admin = AdminMessage()
        build(&admin)
        if !sessionPasskey.isEmpty { admin.sessionPasskey = sessionPasskey }
        var packet = MeshPacket()
        packet.to = state.myNodeNum
        packet.id = newPacketID()
        packet.channel = 0
        packet.wantAck = true
        packet.hopLimit = state.lora?.hopLimit ?? 3
        packet.priority = .reliable
        packet.pkiEncrypted = true
        packet.decoded = DataMessage.with {
            $0.portnum = .adminApp
            $0.payload = (try? admin.serializedData()) ?? Data()
            $0.wantResponse = wantResponse
        }
        try await send(ToRadio.with { $0.packet = packet })
        return packet.id
    }

    /// Asks the node for its admin session key and attaches it to later writes. The firmware only enforces the key for
    /// packets that claim a remote origin, so a local client works without it (the reference client sends its first
    /// write before the reply can arrive); this is best-effort and never blocks or fails an edit.
    private func fetchSessionKey() async {
        guard sessionPasskey.isEmpty else { return }
        guard (try? await sendAdmin { $0.getConfigRequest = .sessionkeyConfig }) != nil else { return }
        let deadline = ContinuousClock.now + .seconds(1.5)
        while sessionPasskey.isEmpty, ContinuousClock.now < deadline {
            let remaining = max(0.1, Double((deadline - .now).components.seconds))
            guard let frame = try? await next(timeout: remaining, what: "session key") else { return }
            absorb(frame)
        }
    }

    /// Waits (briefly) for the routing ACK of `id`, absorbing anything else that arrives. A missing ACK isn't an
    /// error: nodes that reboot to apply a change may not get one out.
    private func awaitAck(_ id: UInt32, timeout: Double = 3) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            let remaining = max(0.1, Double((deadline - .now).components.seconds))
            guard let frame = try? await next(timeout: remaining, what: "ack") else { return }
            absorb(frame)
            guard case .packet(let p)? = frame.payloadVariant, case .decoded(let d)? = p.payloadVariant,
                  d.portnum == .routingApp, d.requestID == id,
                  let routing = try? Routing(serializedBytes: [UInt8](d.payload)) else { continue }
            if case .errorReason(let reason)? = routing.variant, reason != .none {
                throw MeshtasticNodeError.rejected(String(describing: reason))
            }
            return
        }
    }

    public func apply(_ edit: MeshtasticEdit) async throws {
        guard !edit.isEmpty else { return }
        // A managed node silently drops local admin writes; say so rather than reporting a change that didn't happen.
        if state.device?.isManaged == true { throw MeshtasticNodeError.managed }
        await fetchSessionKey()
        try await awaitAck(try await sendAdmin { $0.beginEditSettings = true })
        if edit.longName != nil || edit.shortName != nil {
            let id = try await sendAdmin {
                var user = User()
                if let n = edit.longName { user.longName = n }
                if let s = edit.shortName { user.shortName = String(s.prefix(4)) }
                $0.setOwner = user
            }
            try await awaitAck(id)
        }
        if let lora = edit.lora {
            try await awaitAck(try await sendAdmin { $0.setConfig = Config.with { $0.lora = lora } })
        }
        if let device = edit.device {
            try await awaitAck(try await sendAdmin { $0.setConfig = Config.with { $0.device = device } })
        }
        try await awaitAck(try await sendAdmin { $0.commitEditSettings = true })
    }

    public func syncClock() async throws {
        if state.device?.isManaged == true { throw MeshtasticNodeError.managed }
        await fetchSessionKey()
        try await awaitAck(try await sendAdmin(wantResponse: false) { $0.setTimeOnly = UInt32(Date().timeIntervalSince1970) })
    }

    public func reboot(seconds: Int32 = 5) async throws {
        if state.device?.isManaged == true { throw MeshtasticNodeError.managed }
        await fetchSessionKey()
        try await sendAdmin(wantResponse: false) { $0.rebootSeconds = seconds }
    }
}
