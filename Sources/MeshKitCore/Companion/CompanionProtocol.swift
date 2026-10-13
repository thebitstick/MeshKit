import Foundation

// Layouts follow the MeshCore "Companion Radio Protocol" wiki page. Fields that page does
// not spell out (CMD_SET_RADIO_TX_POWER, CMD_REBOOT, CMD_SEND_SELF_ADVERT, CMD_GET_STATS)
// are marked UNVERIFIED and should be checked against the firmware before shipping.

public enum AdvertType: UInt8, Sendable {
    case none = 0, chat = 1, repeater = 2, room = 3

    public var label: String {
        switch self {
        case .none: "Unknown"
        case .chat: "Companion"
        case .repeater: "Repeater"
        case .room: "Room server"
        }
    }
}

public struct DeviceInfo: Equatable, Sendable {
    public var firmwareVersion: UInt8
    public var maxContacts: Int
    public var maxChannels: Int
    public var blePin: UInt32
    public var buildDate: String
    public var model: String
    public var semanticVersion: String

    static func parse(_ r: inout ByteReader) throws -> DeviceInfo {
        let ver = try r.u8("firmware_ver")
        var info = DeviceInfo(firmwareVersion: ver, maxContacts: 0, maxChannels: 0, blePin: 0,
                              buildDate: "", model: "", semanticVersion: "")
        // Everything after firmware_ver is v3+; tolerate older, shorter replies.
        guard r.remaining >= 2 + 4 else { return info }
        info.maxContacts = Int(try r.u8()) * 2
        info.maxChannels = Int(try r.u8())
        info.blePin = try r.u32()
        if r.remaining >= 12 { info.buildDate = try r.fixedString(12, "build_date") }
        if r.remaining >= 40 { info.model = try r.fixedString(40, "model") }
        if r.remaining >= 20 { info.semanticVersion = try r.fixedString(20, "semantic_version") }
        return info
    }

    func encode() -> [UInt8] {
        var b: [UInt8] = [CompanionResponse.Code.deviceInfo, firmwareVersion, UInt8(maxContacts / 2), UInt8(maxChannels)]
        b.appendLE(blePin)
        b.appendFixedString(buildDate, width: 12)
        b.appendFixedString(model, width: 40)
        b.appendFixedString(semanticVersion, width: 20)
        return b
    }
}

public struct SelfInfo: Equatable, Sendable {
    public var advType: AdvertType
    public var txPowerDBm: Int
    public var maxTxPowerDBm: Int
    public var publicKey: [UInt8]
    public var latitude: Double
    public var longitude: Double
    public var multiAcks: Bool
    public var advertLocationShared: Bool
    public var telemetryModes: UInt8
    public var manualAddContacts: Bool
    public var frequencyMHz: Double
    public var bandwidthKHz: Double
    public var spreadingFactor: Int
    public var codingRate: Int
    public var name: String

    public var publicKeyHex: String { publicKey.map { String(format: "%02x", $0) }.joined() }

    static func parse(_ r: inout ByteReader) throws -> SelfInfo {
        let type = try r.u8("type")
        let tx = try r.u8("tx_power")
        let maxTx = try r.u8("max_tx_power")
        let key = try r.take(32, "public_key")
        let lat = try r.i32("lat"), lon = try r.i32("lon")
        let multi = try r.u8("multi_acks")
        let locPolicy = try r.u8("advert_loc_policy")
        let telemetry = try r.u8("telemetry_modes")
        let manual = try r.u8("manual_add_contacts")
        let freq = try r.u32("radio_freq"), bw = try r.u32("radio_bw")
        let sf = try r.u8("radio_sf"), cr = try r.u8("radio_cr")
        return SelfInfo(
            advType: AdvertType(rawValue: type) ?? .none,
            txPowerDBm: Int(tx), maxTxPowerDBm: Int(maxTx), publicKey: key,
            latitude: Double(lat) / 1e6, longitude: Double(lon) / 1e6,
            multiAcks: multi != 0, advertLocationShared: locPolicy != 0,
            telemetryModes: telemetry, manualAddContacts: manual != 0,
            frequencyMHz: Double(freq) / 1000, bandwidthKHz: Double(bw) / 1000,
            spreadingFactor: Int(sf), codingRate: Int(cr), name: r.restString())
    }

    func encode() -> [UInt8] {
        var b: [UInt8] = [CompanionResponse.Code.selfInfo, advType.rawValue, UInt8(txPowerDBm), UInt8(maxTxPowerDBm)]
        b += publicKey
        b.appendLE(Int32((latitude * 1e6).rounded()))
        b.appendLE(Int32((longitude * 1e6).rounded()))
        b += [multiAcks ? 1 : 0, advertLocationShared ? 1 : 0, telemetryModes, manualAddContacts ? 1 : 0]
        b.appendLE(UInt32((frequencyMHz * 1000).rounded()))
        b.appendLE(UInt32((bandwidthKHz * 1000).rounded()))
        b += [UInt8(spreadingFactor), UInt8(codingRate)]
        b += Array(name.utf8)
        return b
    }
}

public struct Contact: Equatable, Identifiable, Sendable {
    public var publicKey: [UInt8]
    public var type: AdvertType
    public var flags: UInt8
    public var outPathLength: Int8
    public var name: String
    public var lastAdvert: Date
    public var latitude: Double
    public var longitude: Double
    public var lastModified: Date

    public var id: String { publicKeyHex }
    public var publicKeyHex: String { publicKey.map { String(format: "%02x", $0) }.joined() }
    public var hasLocation: Bool { latitude != 0 || longitude != 0 }

    static func parse(_ r: inout ByteReader) throws -> Contact {
        let key = try r.take(32, "public_key")
        let type = try r.u8("type")
        let flags = try r.u8("flags")
        let pathLen = try r.i8("out_path_len")
        _ = try r.take(64, "out_path")
        let name = try r.fixedString(32, "adv_name")
        let lastAdvert = try r.u32("last_advert")
        let lat = try r.i32("lat"), lon = try r.i32("lon")
        let lastMod = try r.u32("lastmod")
        return Contact(
            publicKey: key, type: AdvertType(rawValue: type) ?? .none, flags: flags, outPathLength: pathLen,
            name: name, lastAdvert: Date(timeIntervalSince1970: TimeInterval(lastAdvert)),
            latitude: Double(lat) / 1e6, longitude: Double(lon) / 1e6,
            lastModified: Date(timeIntervalSince1970: TimeInterval(lastMod)))
    }

    func encode() -> [UInt8] {
        var b: [UInt8] = [CompanionResponse.Code.contact] + publicKey + [type.rawValue, flags, UInt8(bitPattern: outPathLength)]
        b += [UInt8](repeating: 0, count: 64)
        b.appendFixedString(name, width: 32)
        b.appendLE(UInt32(lastAdvert.timeIntervalSince1970))
        b.appendLE(Int32((latitude * 1e6).rounded()))
        b.appendLE(Int32((longitude * 1e6).rounded()))
        b.appendLE(UInt32(lastModified.timeIntervalSince1970))
        return b
    }
}

public struct BatteryInfo: Equatable, Sendable {
    public var millivolts: Int
    public var usedKB: UInt32?
    public var totalKB: UInt32?

    public var approxPercent: Int {
        Int(max(0, min(1, (Double(millivolts) - 3300) / 900)) * 100)
    }
}

public enum RadioStats: Equatable, Sendable {
    case core(batteryMV: Int, uptimeSeconds: UInt32, errorFlags: UInt16, queueLength: UInt8)
    case radio(noiseFloor: Int, lastRSSI: Int, lastSNR: Double, txAirSeconds: UInt32, rxAirSeconds: UInt32)
    case packets(received: UInt32, sent: UInt32, sentFlood: UInt32, sentDirect: UInt32, receivedFlood: UInt32, receivedDirect: UInt32)
}

public enum CompanionResponse: Equatable, Sendable {
    case ok
    case err(code: UInt8?)
    case contactsStart(count: UInt32)
    case contact(Contact)
    case endOfContacts(mostRecentLastMod: UInt32)
    case selfInfo(SelfInfo)
    case currentTime(UInt32)
    case battery(BatteryInfo)
    case deviceInfo(DeviceInfo)
    case stats(RadioStats)
    case push(code: UInt8, payload: [UInt8])
    case unknown(code: UInt8, payload: [UInt8])

    public enum Code {
        public static let ok: UInt8 = 0, err: UInt8 = 1, contactsStart: UInt8 = 2, contact: UInt8 = 3
        public static let endOfContacts: UInt8 = 4, selfInfo: UInt8 = 5, currTime: UInt8 = 9
        public static let battery: UInt8 = 12, deviceInfo: UInt8 = 13, stats: UInt8 = 24
    }

    public var isPush: Bool {
        if case .push = self { return true }
        return false
    }

    public static func parse(_ frame: [UInt8]) throws -> CompanionResponse {
        var r = ByteReader(frame)
        let code = try r.u8("response code")
        if code >= 0x80 { return .push(code: code, payload: r.rest()) }
        switch code {
        case Code.ok: return .ok
        case Code.err: return .err(code: r.remaining > 0 ? try r.u8() : nil)
        case Code.contactsStart: return .contactsStart(count: try r.u32("count"))
        case Code.contact: return .contact(try Contact.parse(&r))
        case Code.endOfContacts: return .endOfContacts(mostRecentLastMod: try r.u32("lastmod"))
        case Code.selfInfo: return .selfInfo(try SelfInfo.parse(&r))
        case Code.currTime: return .currentTime(try r.u32("epoch"))
        case Code.deviceInfo: return .deviceInfo(try DeviceInfo.parse(&r))
        case Code.battery:
            let mv = Int(try r.u16("millivolts"))
            let used = r.remaining >= 4 ? try r.u32() : nil
            let total = r.remaining >= 4 ? try r.u32() : nil
            return .battery(BatteryInfo(millivolts: mv, usedKB: used, totalKB: (total ?? 0) == 0 ? nil : total))
        case Code.stats:
            let sub = try r.u8("stats sub_type")
            switch sub {
            case 0:
                return .stats(.core(batteryMV: Int(try r.i16()), uptimeSeconds: try r.u32(), errorFlags: try r.u16(), queueLength: try r.u8()))
            case 1:
                return .stats(.radio(noiseFloor: Int(try r.i16()), lastRSSI: Int(try r.i8()), lastSNR: Double(try r.i8()) / 4,
                                     txAirSeconds: try r.u32(), rxAirSeconds: try r.u32()))
            case 2:
                return .stats(.packets(received: try r.u32(), sent: try r.u32(), sentFlood: try r.u32(),
                                       sentDirect: try r.u32(), receivedFlood: try r.u32(), receivedDirect: try r.u32()))
            default: return .unknown(code: code, payload: [sub] + r.rest())
            }
        default: return .unknown(code: code, payload: r.rest())
        }
    }
}

public enum CompanionRequest {
    public static func deviceQuery(targetVersion: UInt8 = 3) -> [UInt8] { [22, targetVersion] }

    public static func appStart(appVersion: UInt8 = 1, appName: String = "MeshKit") -> [UInt8] {
        [1, appVersion] + [UInt8](repeating: 0, count: 6) + Array(appName.utf8)
    }

    public static func getContacts(since: UInt32? = nil) -> [UInt8] {
        var b: [UInt8] = [4]
        if let since { b.appendLE(since) }
        return b
    }

    public static let getDeviceTime: [UInt8] = [5]

    public static func setDeviceTime(_ epoch: UInt32) -> [UInt8] {
        var b: [UInt8] = [6]; b.appendLE(epoch); return b
    }

    /// UNVERIFIED: one flag byte (1 = flood). Firmware may also accept the bare command.
    public static func sendSelfAdvert(flood: Bool) -> [UInt8] { [7, flood ? 1 : 0] }

    public static func setAdvertName(_ name: String) -> [UInt8] { [8] + Array(name.utf8.prefix(31)) }

    public static func setRadioParams(frequencyMHz: Double, bandwidthKHz: Double, spreadingFactor: Int, codingRate: Int) -> [UInt8] {
        var b: [UInt8] = [11]
        b.appendLE(UInt32((frequencyMHz * 1000).rounded()))
        b.appendLE(UInt32((bandwidthKHz * 1000).rounded()))
        b += [UInt8(spreadingFactor), UInt8(codingRate)]
        return b
    }

    /// UNVERIFIED: single dBm byte.
    public static func setTxPower(_ dBm: Int) -> [UInt8] { [12, UInt8(clamping: dBm)] }

    public static func setAdvertLatLon(latitude: Double, longitude: Double) -> [UInt8] {
        var b: [UInt8] = [14]
        b.appendLE(Int32((latitude * 1e6).rounded()))
        b.appendLE(Int32((longitude * 1e6).rounded()))
        return b
    }

    /// UNVERIFIED: firmware appears to require the literal string "reboot" after the code.
    public static let reboot: [UInt8] = [19] + Array("reboot".utf8)

    public static let getBatteryAndStorage: [UInt8] = [20]

    /// UNVERIFIED sub_type byte: 0 core, 1 radio, 2 packets.
    public static func getStats(subType: UInt8) -> [UInt8] { [56, subType] }
}
