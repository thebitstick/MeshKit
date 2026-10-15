import Foundation
import MeshtasticProtobufs
import SwiftProtobuf

/// A software Meshtastic node speaking the stream API: the configuration handshake, admin reads and writes, and
/// routing ACKs. Admin rules follow the firmware's `AdminModule`: writes that arrive from the local client (packet
/// `from == 0`, i.e. over serial, TCP or BLE) are accepted without a session key unless the node is managed, while
/// writes that claim another origin need the current session key. Served over TCP by `esp-sim --meshtastic` so the
/// reference `meshtastic` CLI can be run against it.
public final class SimulatedMeshtasticNode: ByteTransport, @unchecked Sendable {
    private let broadcaster = DataBroadcaster()
    private let lock = NSLock()
    private var decoder = MeshtasticFrameDecoder()

    private let myNum: UInt32 = 0x1234_ABCD
    private var owner = User.with { $0.id = "!1234abcd"; $0.longName = "Demo Node"; $0.shortName = "DEMO"; $0.hwModel = .heltecV3; $0.role = .client }
    private var lora = Config.LoRaConfig.with {
        $0.usePreset = true; $0.modemPreset = .longFast; $0.region = .us; $0.hopLimit = 3; $0.txEnabled = true; $0.txPower = 0
    }
    private var device = Config.DeviceConfig.with { $0.role = .client; $0.rebroadcastMode = .all; $0.nodeInfoBroadcastSecs = 10_800 }
    private var channels: [Channel]
    private var passkey = Data((0..<8).map { _ in UInt8.random(in: 1...255) })
    private var inTransaction = false
    private var pendingConfigs: [Config] = []

    public private(set) var rejectedAdminMessages = 0
    public private(set) var committedTransactions = 0
    public private(set) var rebootRequests: [Int32] = []
    public private(set) var dfuRequests = 0
    public private(set) var fixedPosition: (latitude: Double, longitude: Double)?

    public init() {
        channels = (0..<8).map { i in
            Channel.with {
                $0.index = Int32(i)
                $0.role = i == 0 ? .primary : .disabled
                if i == 0 { $0.settings = ChannelSettings.with { $0.psk = Data([0x01]); $0.name = "" } }
            }
        }
    }

    // MARK: Inspection

    public var currentOwner: User { lock.withLock { owner } }
    public var currentLoRa: Config.LoRaConfig { lock.withLock { lora } }
    public var currentDevice: Config.DeviceConfig { lock.withLock { device } }
    public func setManaged(_ managed: Bool) { lock.withLock { device.isManaged = managed } }

    // MARK: ByteTransport

    public func subscribe() -> AsyncStream<Data> { broadcaster.subscribe() }
    public func close() { broadcaster.finish() }

    public func send(_ data: Data) async throws {
        let replies: [FromRadio] = lock.withLock {
            decoder.feed(data).compactMap { try? ToRadio(serializedBytes: $0) }.flatMap { handle($0) }
        }
        for r in replies { if let bytes = try? r.serializedData() { broadcaster.yield(MeshtasticStream.frame([UInt8](bytes))) } }
    }

    // MARK: Protocol

    private func handle(_ message: ToRadio) -> [FromRadio] {
        switch message.payloadVariant {
        case .wantConfigID(let id): return handshake(id)
        case .packet(let packet): return handle(packet)
        default: return []
        }
    }

    private func handshake(_ id: UInt32) -> [FromRadio] {
        var out: [FromRadio] = []
        func add(_ build: (inout FromRadio) -> Void) { out.append(FromRadio.with { $0.id = UInt32(out.count + 1); build(&$0) }) }
        add { $0.myInfo = MyNodeInfo.with { $0.myNodeNum = myNum; $0.rebootCount = 3; $0.pioEnv = "heltec-v3"; $0.nodedbCount = 3 } }
        add { $0.metadata = DeviceMetadata.with { $0.firmwareVersion = "2.7.26.54e0d8d"; $0.hwModel = .heltecV3; $0.hasBluetooth_p = true; $0.hasWifi_p = true; $0.role = device.role } }
        for c in allConfigs() { add { $0.config = c } }
        for ch in channels { add { $0.channel = ch } }
        add { $0.nodeInfo = NodeInfo.with { $0.num = myNum; $0.user = owner; $0.lastHeard = 1_790_000_000 } }
        for (i, name) in ["Ridge Router", "Hilltop"].enumerated() {
            add {
                $0.nodeInfo = NodeInfo.with {
                    $0.num = 0xAA00_0001 + UInt32(i)
                    $0.user = User.with { $0.id = String(format: "!%08x", 0xAA00_0001 + UInt32(i)); $0.longName = name; $0.shortName = String(name.prefix(4)).uppercased(); $0.hwModel = .tbeam }
                    $0.snr = 6.5 - Float(i) * 3; $0.lastHeard = 1_790_000_000 - UInt32(i) * 600; $0.hopsAway = UInt32(i)
                }
            }
        }
        add { $0.configCompleteID = id }
        return out
    }

    private func allConfigs() -> [Config] {
        [Config.with { $0.device = device }, Config.with { $0.position = Config.PositionConfig() },
         Config.with { $0.power = Config.PowerConfig() }, Config.with { $0.network = Config.NetworkConfig() },
         Config.with { $0.display = Config.DisplayConfig() }, Config.with { $0.lora = lora },
         Config.with { $0.bluetooth = Config.BluetoothConfig.with { $0.enabled = true } },
         Config.with { $0.security = Config.SecurityConfig() }]
    }

    private func handle(_ packet: MeshPacket) -> [FromRadio] {
        guard case .decoded(let data)? = packet.payloadVariant, data.portnum == .adminApp,
              let admin = try? AdminMessage(serializedBytes: [UInt8](data.payload)) else { return [] }
        var out: [FromRadio] = []
        if ProcessInfo.processInfo.environment["MESHKIT_SIM_TRACE"] != nil {
            let variant = admin.payloadVariant.map { String(describing: $0).prefix(60) } ?? "nil"
            print("sim admin: \(variant) key=\(admin.sessionPasskey.count == 0 ? "none" : admin.sessionPasskey == passkey ? "ok" : "WRONG") wantAck=\(packet.wantAck) wantResp=\(data.wantResponse) to=\(String(packet.to, radix: 16)) pki=\(packet.pkiEncrypted) ch=\(packet.channel)")
            fflush(stdout)
        }

        func reply(_ build: (inout AdminMessage) -> Void) {
            var response = AdminMessage(); build(&response)
            response.sessionPasskey = passkey                 // every admin reply carries the current key
            out.append(deliver(portnum: .adminApp, payload: (try? response.serializedData()) ?? Data(), requestID: packet.id))
        }
        func ack(_ reason: Routing.Error) {
            guard packet.wantAck else { return }
            let routing = Routing.with { $0.errorReason = reason }
            out.append(deliver(portnum: .routingApp, payload: (try? routing.serializedData()) ?? Data(), requestID: packet.id))
        }

        switch admin.payloadVariant {
        case .getConfigRequest(let type):
            switch type {
            case .sessionkeyConfig: reply { $0.getConfigResponse = Config.with { $0.sessionkey = Config.SessionkeyConfig() } }
            case .loraConfig: reply { $0.getConfigResponse = Config.with { $0.lora = lora } }
            case .deviceConfig: reply { $0.getConfigResponse = Config.with { $0.device = device } }
            default: reply { $0.getConfigResponse = Config() }
            }
            ack(.none)
        case .getOwnerRequest: reply { $0.getOwnerResponse = owner }; ack(.none)
        case .getChannelRequest(let n): reply { $0.getChannelResponse = channels[Int(max(1, n)) - 1] }; ack(.none)

        // Writes. A managed node ignores local admin entirely; remote-origin writes need the session key.
        default:
            if packet.from == 0, device.isManaged { rejectedAdminMessages += 1; return out }
            if packet.from != 0, admin.sessionPasskey != passkey { rejectedAdminMessages += 1; ack(.adminBadSessionKey); return out }
            switch admin.payloadVariant {
            case .beginEditSettings: inTransaction = true; pendingConfigs = []
            case .setOwner(let u):
                if !u.longName.isEmpty { owner.longName = u.longName }
                if !u.shortName.isEmpty { owner.shortName = u.shortName }
            case .setConfig(let c):
                if case .lora(let l)? = c.payloadVariant { lora = l }
                if case .device(let d)? = c.payloadVariant { device = d; owner.role = d.role }
            case .setFixedPosition(let p): fixedPosition = (Double(p.latitudeI) / 1e7, Double(p.longitudeI) / 1e7)
            case .setChannel(let c): channels[Int(c.index)] = c
            case .commitEditSettings: inTransaction = false; committedTransactions += 1
            case .rebootSeconds(let s): rebootRequests.append(s)
            case .enterDfuModeRequest(let on): if on { dfuRequests += 1 }
            default: break
            }
            if data.wantResponse { reply { _ in } }
            ack(.none)
        }
        return out
    }

    private func deliver(portnum: PortNum, payload: Data, requestID: UInt32) -> FromRadio {
        FromRadio.with {
            $0.id = UInt32.random(in: 1...0xFFFF)
            $0.packet = MeshPacket.with {
                $0.from = myNum; $0.to = myNum; $0.id = UInt32.random(in: 1...0x7FFF_FFFF)
                $0.decoded = DataMessage.with { $0.portnum = portnum; $0.payload = payload; $0.requestID = requestID }
            }
        }
    }
}
