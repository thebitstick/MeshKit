import Foundation

public struct CLISetting: Identifiable, Sendable {
    public enum Kind: Sendable {
        case text
        case secret
        case onOff
        case number(ClosedRange<Double>)
        case choice([String])
        case radio
    }

    public let id: String
    public let label: String
    public let group: String
    public let help: String
    public let kind: Kind
    public var requiresReboot = false
    public var sensitive = false
    /// A number setting where 0 turns the feature off even though it lies outside the usual range.
    public var allowsZero = false

    public var getCommand: String { "get \(id)" }
    public func setCommand(_ value: String) -> String { "set \(id) \(value)" }
}

public enum CLICatalog {
    private static func s(_ id: String, _ label: String, _ group: String, _ kind: CLISetting.Kind,
                          _ help: String, reboot: Bool = false, sensitive: Bool = false, allowsZero: Bool = false) -> CLISetting {
        CLISetting(id: id, label: label, group: group, help: help, kind: kind, requiresReboot: reboot, sensitive: sensitive, allowsZero: allowsZero)
    }

    public static let groups = ["Identity", "Radio", "Routing", "Adverts"]

    public static let all: [CLISetting] = [
        s("name", "Node name", "Identity", .text, "Shown to other nodes (about 23–31 UTF-8 bytes)."),
        s("lat", "Latitude", "Identity", .number(-90...90), "Degrees. 0 means unset."),
        s("lon", "Longitude", "Identity", .number(-180...180), "Degrees. 0 means unset."),
        s("owner.info", "Owner info", "Identity", .text, "Free text; use | for newlines."),
        s("guest.password", "Guest password", "Identity", .secret, "Blank allows guest login without a password.", sensitive: true),

        s("radio", "Radio parameters", "Radio", .radio, "Frequency (MHz), bandwidth (kHz), spreading factor, coding rate.", reboot: true),
        s("tx", "TX power (dBm)", "Radio", .number(1...22), "Maximum depends on the board."),
        s("radio.rxgain", "RX boost", "Radio", .onOff, "Boosted receive gain, where the radio supports it."),

        s("repeat", "Repeat packets", "Routing", .onOff, "Turn off to make this a listen-only node."),
        s("path.hash.mode", "Path hash size", "Routing", .number(0...2), "Bytes per hop hash in flood paths (0–2)."),
        s("loop.detect", "Loop detection", "Routing", .choice(["off", "minimal", "moderate", "strict"]), "How aggressively to drop looping floods."),
        s("txdelay", "Flood TX delay", "Routing", .number(0...2), "Retransmit delay factor for flood packets."),
        s("direct.txdelay", "Direct TX delay", "Routing", .number(0...2), "Retransmit delay factor for direct packets."),
        s("rxdelay", "RX delay", "Routing", .number(0...20), "Delay base for weaker signals; 0 disables."),
        s("dutycycle", "Duty cycle (%)", "Routing", .number(1...100), "Airtime budget. 50% equals airtime factor 1.0."),
        s("int.thresh", "Interference threshold", "Routing", .number(0...100), "Listen-before-talk threshold; 0 disables."),
        s("agc.reset.interval", "AGC reset interval (s)", "Routing", .number(0...3600), "Multiple of 4; 0 disables."),
        s("multi.acks", "Multi-acks", "Routing", .number(0...1), "0 off, 1 on."),
        s("flood.max", "Max flood hops", "Routing", .number(0...64), "Floods beyond this are not repeated."),
        s("flood.max.advert", "Max advert hops", "Routing", .number(0...64), "Hop limit for flooded adverts."),

        s("flood.advert.interval", "Flood advert interval (h)", "Adverts", .number(3...168), "Hours between network-wide adverts."),
        s("advert.interval", "Local advert interval (min)", "Adverts", .number(60...240), "Minutes between zero-hop adverts; 0 disables.", allowsZero: true),
    ]

    public static var backupable: [CLISetting] { all.filter { !$0.sensitive } }

    public static func setting(_ id: String) -> CLISetting? { all.first { $0.id == id } }
}

public struct CLICommand: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let command: String
    public let symbol: String
    public let destructive: Bool
    public let expectsReply: Bool

    /// What to send now: the serial console sets the clock with `time <epoch>`; `clock sync` only works from a remote login.
    public var resolvedCommand: String { id == "clocksync" ? "time \(Int(Date().timeIntervalSince1970))" : command }

    public static let quickActions: [CLICommand] = [
        .init(id: "advert", title: "Flood advert", command: "advert", symbol: "dot.radiowaves.left.and.right", destructive: false, expectsReply: true),
        .init(id: "zerohop", title: "Local advert", command: "advert.zerohop", symbol: "antenna.radiowaves.left.and.right", destructive: false, expectsReply: true),
        .init(id: "neighbors", title: "Neighbors", command: "neighbors", symbol: "point.3.connected.trianglepath.dotted", destructive: false, expectsReply: true),
        .init(id: "clock", title: "Read clock", command: "clock", symbol: "clock", destructive: false, expectsReply: true),
        .init(id: "clocksync", title: "Sync clock", command: "clock sync", symbol: "clock.arrow.2.circlepath", destructive: false, expectsReply: true),
        .init(id: "ver", title: "Firmware version", command: "ver", symbol: "number", destructive: false, expectsReply: true),
        .init(id: "reboot", title: "Reboot", command: "reboot", symbol: "restart", destructive: false, expectsReply: false),
        .init(id: "erase", title: "Factory reset", command: "erase", symbol: "trash", destructive: true, expectsReply: true),
    ]
}
