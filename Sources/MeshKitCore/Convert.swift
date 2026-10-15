import Foundation

/// What can be carried from a MeshCore node to a Meshtastic one, or back. The identity key, radio settings and
/// channels don't translate between the two (different key formats, different channel models), so only the name and
/// the location do.
public struct NodeIdentity: Equatable, Sendable {
    public var name: String
    public var latitude: Double?
    public var longitude: Double?

    public init(name: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.name = name
        if let latitude, let longitude, !(latitude == 0 && longitude == 0), abs(latitude) <= 90, abs(longitude) <= 180 {
            self.latitude = latitude; self.longitude = longitude
        }
    }

    public var hasLocation: Bool { latitude != nil }

    /// Meshtastic's four-character name: the initials of a name with several words, else its first four characters.
    public var shortName: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.count >= 2 ? words.compactMap(\.first).map(String.init).joined() : (words.first.map(String.init) ?? "")
        return NameLimits.fit(letters.uppercased(), bytes: NameLimits.meshtasticShort)
    }

    public var summary: String {
        var parts = [name.isEmpty ? "no name" : "name “\(name)”"]
        if let latitude, let longitude { parts.append(String(format: "location %.5f, %.5f", latitude, longitude)) }
        return parts.joined(separator: " and ")
    }
}

/// MeshCore and Meshtastic name the same board differently. Only boards listed here can be converted.
public enum BoardPairs {
    static let pairs: [(meshCore: String, meshtastic: String)] = [
        ("wiotrackerl1", "seeed_wio_tracker_L1"), ("wiotrackerl1eink", "seeed_wio_tracker_L1_eink"),
        ("heltec_t114", "heltec-mesh-node-t114"), ("heltec_t114_without_display", "heltec-mesh-node-t114"),
        ("heltec_t096", "heltec-mesh-node-t096"), ("heltec_t1", "heltec-mesh-node-t1"),
        ("lilygo_t-echo", "t-echo"), ("rak_4631", "rak4631"), ("rak_3401", "rak3401-1watt"), ("rak_wismesh_tag", "rak_wismeshtag"),
        ("thinknode_m1", "thinknode_m1"), ("thinknode_m3", "thinknode_m3"), ("thinknode_m6", "thinknode_m6"),
        ("t1000e", "tracker-t1000-e"), ("sensecap_solar", "seeed_solar_node"), ("xiao_nrf52", "seeed_xiao_nrf52840_kit"),
        ("promicro", "nrf52_promicro_diy_tcxo"),
    ]

    /// ESP32 boards whose two names are the same apart from case and punctuation, checked against the MeshCore 1.17.1 and
    /// Meshtastic 2.7.26 releases. Boards whose names differ are left out until someone has checked them.
    static let espPairs: [(meshCore: String, meshtastic: String)] = [
        ("Heltec_v3", "heltec-v3"), ("heltec_v4", "heltec-v4"), ("heltec_v4_tft", "heltec-v4-tft"), ("heltec_v4_r8_tft", "heltec-v4-r8-tft"),
        ("Heltec_Wireless_Paper", "heltec-wireless-paper"), ("Heltec_Wireless_Tracker", "heltec-wireless-tracker"),
        ("Station_G2", "station-g2"), ("M5Stack_Unit_C6L", "m5stack-unitc6l"),
        ("ThinkNode_M2", "thinknode_m2"), ("ThinkNode_M5", "thinknode_m5"), ("ThinkNode_M7", "thinknode_m7"),
    ]

    public static func meshtasticSlug(forMeshCoreBoard slug: String) -> String? {
        let key = slug.lowercased()
        return pairs.first { $0.meshCore == key }?.meshtastic ?? espPairs.first { $0.meshCore.lowercased() == key }?.meshtastic
    }

    public static func meshCoreSlug(forMeshtasticBoard slug: String) -> String? {
        let key = slug.lowercased()
        return pairs.first { $0.meshtastic.lowercased() == key }?.meshCore ?? espPairs.first { $0.meshtastic.lowercased() == key }?.meshCore
    }
}

public enum IdentityTransfer {
    public enum TransferError: LocalizedError {
        case boardDidNotAnswer(String)
        case notKept(String)
        public var errorDescription: String? {
            switch self {
            case .notKept(let why): "The name and location didn't stick: \(why). Set them in Configure."
            case .boardDidNotAnswer(let what): "The board didn't answer as \(what) after the install, so its name and location weren't set. Connect to it and set them by hand."
            }
        }
    }

    /// The first USB serial port of an nRF52 board that appears within `timeout`.
    public static func waitForPort(timeout: Duration, ports: @Sendable () -> [String] = { NRF52SerialCleanFlasher.usbModemPorts() }) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let port = ports().first { return port }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// Opens the board's serial port after an install. An ESP32 comes back on the same port; an nRF52 may come back under
    /// another name, so with no path given it opens the first USB modem port that shows up.
    public static func openPort(_ path: String?, timeout: Duration = .seconds(60)) async throws -> ByteTransport {
        if let path {
            let deadline = ContinuousClock.now + timeout
            while !FileManager.default.fileExists(atPath: path) {
                if ContinuousClock.now > deadline { throw TransferError.boardDidNotAnswer("anything (\(path) did not come back)") }
                try await Task.sleep(for: .milliseconds(500))
            }
            try await Task.sleep(for: .seconds(2))
            return try SerialPort(path: path)
        }
        return try await openNewPort(timeout: timeout)
    }

    /// Opens the board's serial port once it shows up after an install.
    public static func openNewPort(timeout: Duration = .seconds(60)) async throws -> ByteTransport {
        guard let path = await waitForPort(timeout: timeout) else { throw TransferError.boardDidNotAnswer("anything (no serial port appeared)") }
        try await Task.sleep(for: .seconds(2))
        return try SerialPort(path: path)
    }

    public static func apply(_ identity: NodeIdentity, toMeshtastic client: MeshtasticClient) async throws {
        _ = try await client.connect(timeout: 25)
        var edit = MeshtasticEdit()
        if !identity.name.isEmpty { edit.longName = identity.name; edit.shortName = identity.shortName }
        edit.fixedPosition = identity.latitude.flatMap { lat in identity.longitude.map { (lat, $0) } }
        try await client.apply(edit)
    }

    public static func apply(_ identity: NodeIdentity, toCompanion client: CompanionClient) async throws {
        if !identity.name.isEmpty { try await client.setName(identity.name) }
        if let latitude = identity.latitude, let longitude = identity.longitude { try await client.setLocation(latitude: latitude, longitude: longitude) }
    }

    /// Waits for the freshly installed board to boot and answer, then sets the carried values.
    public static func carryOver(_ identity: NodeIdentity, toMeshtasticAt open: @Sendable () async throws -> ByteTransport,
                                 attempts: Int = 6, pause: Duration = .seconds(5), logger: (@Sendable (String) -> Void)? = nil) async throws {
        for attempt in 1...attempts {
            let transport = try await open()
            let client = MeshtasticClient(transport: transport, logger: logger)
            if await client.probe(timeout: 4) {
                do {
                    try await apply(identity, toMeshtastic: client)
                    await client.stop(); transport.close()
                    return
                } catch {
                    await client.stop(); transport.close()
                    if attempt == attempts { throw error }
                }
            } else {
                await client.stop(); transport.close()
            }
            try? await Task.sleep(for: pause)
        }
        throw TransferError.boardDidNotAnswer("Meshtastic")
    }

    public static func carryOver(_ identity: NodeIdentity, toCompanionAt open: @Sendable () async throws -> ByteTransport,
                                 attempts: Int = 6, pause: Duration = .seconds(5), logger: (@Sendable (String) -> Void)? = nil) async throws {
        var lastProblem = "the board never answered"
        for attempt in 1...attempts {
            let transport = try await open()
            let client = CompanionClient(transport: transport, logger: nil)
            await client.start()
            if (try? await client.handshake()) != nil {
                logger?("carry-over: companion answered on attempt \(attempt)")
                do {
                    try await apply(identity, toCompanion: client)
                    // Read it back: a board still on its first boot can answer and then lose what was written.
                    try await Task.sleep(for: .seconds(1))
                    let (_, me) = try await client.handshake()
                    if verified(me, matches: identity) {
                        logger?("carry-over: read back \(me.name) \(me.latitude), \(me.longitude)")
                        await client.stop(); transport.close()
                        return
                    }
                    lastProblem = "it answered with “\(me.name)” after the values were written"
                    logger?("carry-over: read back \(me.name) \(me.latitude), \(me.longitude), not what was written; trying again")
                } catch {
                    lastProblem = error.localizedDescription
                    logger?("carry-over: \(error.localizedDescription)")
                }
            } else {
                logger?("carry-over: no answer on attempt \(attempt)")
            }
            await client.stop(); transport.close()
            try? await Task.sleep(for: pause)
        }
        throw TransferError.notKept(lastProblem)
    }

    /// Repeater and room-server firmware: the same, through the text console (`set name`, `set lat`, `set lon`).
    public static func carryOver(_ identity: NodeIdentity, toRepeaterAt open: @Sendable () async throws -> ByteTransport,
                                 attempts: Int = 6, pause: Duration = .seconds(5), logger: (@Sendable (String) -> Void)? = nil) async throws {
        var lastProblem = "the board never answered"
        for attempt in 1...attempts {
            let transport = try await open()
            let client = RepeaterCLIClient(transport: transport, logger: nil)
            await client.start()
            if let (_, heard) = try? await client.exchange("ver", quiet: .milliseconds(300), timeout: .seconds(2)), heard {
                logger?("carry-over: console answered on attempt \(attempt)")
                do {
                    try await applyAndVerify(identity, toRepeater: client, logger: logger)
                    await client.stop(); transport.close()
                    return
                } catch {
                    lastProblem = error.localizedDescription
                    logger?("carry-over: \(error.localizedDescription)")
                }
            } else {
                logger?("carry-over: no answer on attempt \(attempt)")
            }
            await client.stop(); transport.close()
            try? await Task.sleep(for: pause)
        }
        throw TransferError.notKept(lastProblem)
    }

    private static func applyAndVerify(_ identity: NodeIdentity, toRepeater client: RepeaterCLIClient, logger: (@Sendable (String) -> Void)?) async throws {
        let name = CLICatalog.setting("name")!, lat = CLICatalog.setting("lat")!, lon = CLICatalog.setting("lon")!
        if !identity.name.isEmpty { try await client.runChecked(name.setCommand(identity.name)) }
        if let la = identity.latitude, let lo = identity.longitude {
            try await client.runChecked(lat.setCommand(String(la)))
            try await client.runChecked(lon.setCommand(String(lo)))
        }
        try await Task.sleep(for: .seconds(1))
        if !identity.name.isEmpty {
            guard case .value(let got) = try await client.read(name), got == identity.name else {
                throw TransferError.notKept("the name did not read back")
            }
            logger?("carry-over: read back \(got)")
        }
        if let la = identity.latitude, let lo = identity.longitude {
            guard case .value(let a) = try await client.read(lat), case .value(let b) = try await client.read(lon),
                  let x = Double(a), let y = Double(b), abs(x - la) <= 1e-4, abs(y - lo) <= 1e-4 else {
                throw TransferError.notKept("the location did not read back")
            }
        }
    }

    static func verified(_ me: SelfInfo, matches identity: NodeIdentity) -> Bool {
        if !identity.name.isEmpty, me.name != identity.name { return false }
        if let lat = identity.latitude, let lon = identity.longitude, abs(me.latitude - lat) > 1e-4 || abs(me.longitude - lon) > 1e-4 { return false }
        return true
    }
}
