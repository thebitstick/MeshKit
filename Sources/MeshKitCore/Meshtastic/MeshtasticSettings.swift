import Foundation
import MeshtasticProtobufs

public enum MeshtasticLabels {
    public static func region(_ r: Config.LoRaConfig.RegionCode) -> String {
        switch r {
        case .unset: return "Not set"
        case .lora24: return "2.4 GHz"
        case .UNRECOGNIZED(let n): return "Region \(n)"
        default: break
        }
        let raw = String(describing: r)
        let letters = raw.prefix { $0.isLetter }, digits = raw.dropFirst(letters.count)
        return digits.isEmpty ? letters.uppercased() : "\(letters.uppercased()) \(digits)"
    }

    public static func camel(_ identifier: String) -> String {
        var out = ""
        for ch in identifier {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(out.isEmpty ? Character(ch.uppercased()) : ch)
        }
        return out
    }

    public static func modemPreset(_ p: Config.LoRaConfig.ModemPreset) -> String {
        if case .UNRECOGNIZED(let n) = p { return "Preset \(n)" }
        return camel(String(describing: p))
    }

    public static func role(_ r: Config.DeviceConfig.Role) -> String {
        if case .UNRECOGNIZED(let n) = r { return "Role \(n)" }
        return camel(String(describing: r))
    }

    public static func channelRole(_ r: Channel.Role) -> String {
        switch r {
        case .primary: "Primary"
        case .secondary: "Secondary"
        case .disabled: "Disabled"
        case .UNRECOGNIZED(let n): "Role \(n)"
        }
    }

    public static func keySummary(_ psk: Data) -> String {
        switch psk.count {
        case 0: "No encryption"
        case 1: "Default key"
        case 16: "AES-128 key"
        case 32: "AES-256 key"
        default: "\(psk.count)-byte key"
        }
    }
}

public enum MeshtasticValues {
    public static func snapshot(of state: MeshtasticNodeState) -> [String: String] {
        var v: [String: String] = [:]
        if let o = state.owner { v["owner.long"] = o.longName; v["owner.short"] = o.shortName }
        if let l = state.lora {
            v["lora.region"] = String(l.region.rawValue)
            v["lora.preset"] = String(l.modemPreset.rawValue)
            v["lora.hop"] = String(l.hopLimit)
            v["lora.txpower"] = String(l.txPower)
            v["lora.txenabled"] = l.txEnabled ? "true" : "false"
        }
        if let d = state.device { v["device.role"] = String(d.role.rawValue) }
        return v
    }

    public static func edit(from values: [String: String], current: MeshtasticNodeState) -> MeshtasticEdit {
        var edit = MeshtasticEdit()
        if let long = values["owner.long"], long != current.owner?.longName { edit.longName = long }
        if let short = values["owner.short"], short != current.owner?.shortName { edit.shortName = short }

        if var lora = current.lora {
            let before = lora
            if let n = values["lora.region"].flatMap(Int.init), let r = Config.LoRaConfig.RegionCode(rawValue: n) { lora.region = r }
            if let n = values["lora.preset"].flatMap(Int.init), let p = Config.LoRaConfig.ModemPreset(rawValue: n) { lora.modemPreset = p; lora.usePreset = true }
            if let n = values["lora.hop"].flatMap(UInt32.init) { lora.hopLimit = n }
            if let n = values["lora.txpower"].flatMap(Int32.init) { lora.txPower = n }
            if let b = values["lora.txenabled"] { lora.txEnabled = b == "true" }
            if lora != before { edit.lora = lora }
        }
        if var device = current.device, let n = values["device.role"].flatMap(Int.init), let r = Config.DeviceConfig.Role(rawValue: n), r != device.role {
            device.role = r
            edit.device = device
        }
        return edit
    }
}
