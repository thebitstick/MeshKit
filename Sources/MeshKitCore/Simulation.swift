import Foundation

public final class SimulatedCompanionTransport: ByteTransport, @unchecked Sendable {
    private let broadcaster = DataBroadcaster()
    private let lock = NSLock()
    private var decoder = FrameDecoder(marker: USBFrame.toRadioMarker)
    private var me: SelfInfo
    private var contacts: [Contact]

    public init(name: String = "Demo Companion") {
        me = SelfInfo(advType: .chat, txPowerDBm: 14, maxTxPowerDBm: 22,
                      publicKey: (0..<32).map { UInt8(($0 * 37 + 11) & 0xFF) },
                      latitude: 37.7749, longitude: -122.4194, multiAcks: false, advertLocationShared: true,
                      telemetryModes: 0, manualAddContacts: false, frequencyMHz: 910.525, bandwidthKHz: 62.5,
                      spreadingFactor: 7, codingRate: 5, name: name)
        let now = Date()
        contacts = [("Ridge Repeater", AdvertType.repeater, 37.80, -122.45), ("Bay Room", .room, 37.76, -122.40),
                    ("Sam", .chat, 0, 0), ("Avery", .chat, 37.78, -122.41), ("Hilltop Repeater", .repeater, 37.85, -122.50)]
            .enumerated().map { i, c in
                Contact(publicKey: (0..<32).map { UInt8(($0 * (i + 3) + i * 17) & 0xFF) }, type: c.1, flags: 0,
                        outPathLength: Int8(i), name: c.0, lastAdvert: now.addingTimeInterval(-Double(i) * 1800),
                        latitude: c.2, longitude: c.3, lastModified: now.addingTimeInterval(-Double(i) * 900))
            }
    }

    public func subscribe() -> AsyncStream<Data> { broadcaster.subscribe() }
    public func close() { broadcaster.finish() }

    public func send(_ data: Data) async throws {
        let replies = lock.withLock { decoder.feed(data).flatMap { respond(to: $0) } }
        for payload in replies { broadcaster.yield(USBFrame.encode(payload, marker: USBFrame.fromRadioMarker)) }
    }

    private func respond(to frame: [UInt8]) -> [[UInt8]] {
        guard let code = frame.first else { return [] }
        var r = ByteReader(Array(frame.dropFirst()))
        let ok: [[UInt8]] = [[CompanionResponse.Code.ok]]
        let err: [[UInt8]] = [[CompanionResponse.Code.err, 1]]
        switch code {
        case 22:
            return [DeviceInfo(firmwareVersion: 9, maxContacts: 350, maxChannels: 8, blePin: 123456,
                               buildDate: "05 Oct 2026", model: "Simulated Heltec V3", semanticVersion: "v1.17.1").encode()]
        case 1: return [me.encode()]
        case 4:
            var out: [[UInt8]] = [[CompanionResponse.Code.contactsStart] + withUnsafeBytes(of: UInt32(contacts.count).littleEndian, Array.init)]
            out += contacts.map { $0.encode() }
            out.append([CompanionResponse.Code.endOfContacts] + withUnsafeBytes(of: UInt32(Date().timeIntervalSince1970).littleEndian, Array.init))
            return out
        case 5: return [[CompanionResponse.Code.currTime] + withUnsafeBytes(of: UInt32(Date().timeIntervalSince1970).littleEndian, Array.init)]
        case 6, 7, 19: return ok
        case 8:
            me.name = String(decoding: frame.dropFirst(), as: UTF8.self); return ok
        case 11:
            guard let f = try? r.u32(), let bw = try? r.u32(), let sf = try? r.u8(), let cr = try? r.u8() else { return err }
            me.frequencyMHz = Double(f) / 1000; me.bandwidthKHz = Double(bw) / 1000
            me.spreadingFactor = Int(sf); me.codingRate = Int(cr); return ok
        case 12:
            guard let p = try? r.u8() else { return err }
            me.txPowerDBm = Int(p); return ok
        case 14:
            guard let lat = try? r.i32(), let lon = try? r.i32() else { return err }
            me.latitude = Double(lat) / 1e6; me.longitude = Double(lon) / 1e6; return ok
        case 20:
            var b: [UInt8] = [CompanionResponse.Code.battery]
            b.appendLE(UInt16(3920)); b.appendLE(UInt32(412)); b.appendLE(UInt32(1536))
            return [b]
        case 56:
            var b: [UInt8] = [CompanionResponse.Code.stats]
            switch (try? r.u8()) ?? 0 {
            case 0: b += [0]; b.appendLE(Int16(3920)); b.appendLE(UInt32(86_400 + 3_725)); b.appendLE(UInt16(0)); b.append(0)
            case 1: b += [1]; b.appendLE(Int16(-112)); b.append(UInt8(bitPattern: -96)); b.append(UInt8(bitPattern: 34)); b.appendLE(UInt32(210)); b.appendLE(UInt32(1840))
            default: b += [2]; for v: UInt32 in [1204, 388, 301, 87, 902, 302] { b.appendLE(v) }
            }
            return [b]
        default: return err
        }
    }
}

public final class SimulatedRepeaterTransport: ByteTransport, @unchecked Sendable {
    private let broadcaster = DataBroadcaster()
    private let lock = NSLock()
    private var pendingLine = ""
    private var store: [String: String] = [
        "name": "Demo Repeater", "lat": "37.8044", "lon": "-122.2712", "owner.info": "Demo owner|Oakland, CA",
        "guest.password": "", "radio": "910.525,62.5,7,5", "tx": "20", "radio.rxgain": "on", "repeat": "on",
        "path.hash.mode": "0", "loop.detect": "off", "txdelay": "0.5", "direct.txdelay": "0.2", "rxdelay": "0",
        "dutycycle": "50", "int.thresh": "0", "agc.reset.interval": "0", "multi.acks": "0", "flood.max": "64",
        "flood.max.advert": "8", "flood.advert.interval": "12", "advert.interval": "0",
    ]

    public init() {}
    public func subscribe() -> AsyncStream<Data> { broadcaster.subscribe() }
    public func close() { broadcaster.finish() }

    public func send(_ data: Data) async throws {
        let lines: [String] = lock.withLock {
            var lines: [String] = []
            // Iterate scalars, not Characters: Swift treats "\r\n" as a single Character.
            for ch in String(decoding: data, as: UTF8.self).unicodeScalars {
                if ch == "\r" { lines.append(pendingLine); pendingLine = "" } else if ch != "\n" { pendingLine.unicodeScalars.append(ch) }
            }
            return lines
        }
        for line in lines {
            try await Task.sleep(for: .milliseconds(30))
            broadcaster.yield(Data((line + "\r\n" + reply(to: line)).utf8))
        }
    }

    private func reply(to line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        func out(_ s: String) -> String { "  -> \(s)\r\n" }
        switch line {
        case "ver": return out("v1.17.1 (05 Oct 2026)")
        case "board": return out("Simulated Heltec V3")
        case "clock": return out("12:34 - 5/10/2026 UTC")
        case "clock sync": return out("OK - clock set")
        case "advert", "advert.zerohop": return out("OK - Advert sent")
        case "neighbors": return out("a1b2c3d4:1790000000:36\r\ne5f60718:1790000300:28")
        case "reboot": return ""
        default: break
        }
        switch parts.first {
        case "get" where parts.count >= 2:
            lock.lock(); defer { lock.unlock() }
            return store[parts[1]].map(out) ?? out("Error: unknown config")
        case "set" where parts.count >= 3:
            lock.lock(); defer { lock.unlock() }
            guard store[parts[1]] != nil else { return out("Error: unknown config") }
            store[parts[1]] = parts[2]
            return out("OK" + (["radio", "freq", "prv.key"].contains(parts[1]) ? " - reboot to apply" : ""))
        default: return out("Unknown command")
        }
    }
}
