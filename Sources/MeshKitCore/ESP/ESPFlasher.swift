import Foundation

public enum ESPImageCheck {
    /// Application images start with 0xE9 and carry the chip ID at byte 12 of the header.
    public static let imageMagic: UInt8 = 0xE9

    public static func validate(_ image: [UInt8], at address: UInt32, chip: ESPChip, flashSize: Int?, isApplication: Bool = true) throws {
        guard !image.isEmpty else { throw ESPError.emptyImage }
        if let flashSize, Int(address) + image.count > flashSize {
            throw ESPError.imageTooLarge(size: Int(address) + image.count, flashSize: flashSize)
        }
        guard isApplication else { return }
        // The header is at the start of the image; a merged image written at 0x0 also has the bootloader header
        // at the chip's bootloader offset.
        var offsets = [0]
        let bootloaderRelative = Int(chip.bootloaderOffset) - Int(address)
        if bootloaderRelative > 0 { offsets.append(bootloaderRelative) }
        for offset in offsets {
            guard offset + 14 <= image.count, image[offset] == imageMagic else { continue }
            let id = UInt16(image[offset + 12]) | UInt16(image[offset + 13]) << 8
            guard id == chip.imageChipID else {
                throw ESPError.imageForDifferentChip(found: ESPChip.name(forImageChipID: id), expected: chip.rawValue)
            }
        }
    }
}

public struct ESPFlashBackup: Sendable {
    public let chip: ESPChip
    public let flashSize: Int
    public let date: Date
    public let data: [UInt8]
}

public enum FlashBackupStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeshKit/FlashBackups", isDirectory: true)
    }

    public struct Entry: Identifiable, Hashable, Sendable {
        public let url: URL
        public let chip: String
        public let date: Date
        public let size: Int
        /// What the image holds ("MeshCore v1.17.1 (d929643)"), read from the version strings in it.
        public let firmware: String?
        public var id: URL { url }
    }

    /// Names the firmware in a full flash image from its version strings. The match nearest the start of flash is the
    /// firmware; one found further on is reported as left over from an earlier install.
    public static func describe(_ image: Data) -> String? {
        let text = String(decoding: image.map { $0 < 0x20 || $0 > 0x7e ? UInt8(ascii: " ") : $0 }, as: UTF8.self)
        let meshCore = #/\bv(\d+\.\d+\.\d+)-([0-9a-f]{7})\b/#
        let meshtastic = #/\b(\d+\.\d+\.\d+)\.([0-9a-f]{7})\b/#
        var found: [(offset: Int, name: String, version: String)] = []
        for m in text.matches(of: meshCore) { found.append((text.distance(from: text.startIndex, to: m.range.lowerBound), "MeshCore", "v\(m.1) (\(m.2))")) }
        for m in text.matches(of: meshtastic) { found.append((text.distance(from: text.startIndex, to: m.range.lowerBound), "Meshtastic", "\(m.1) (\(m.2))")) }
        found.sort { $0.offset < $1.offset }
        guard let first = found.first else { return nil }
        let label = "\(first.name) \(first.version)"
        guard let other = found.first(where: { $0.name != first.name }) else { return label }
        return "\(label), with leftovers of \(other.name) \(other.version)"
    }

    private static let labels = LabelCache()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    @discardableResult
    public static func save(_ backup: ESPFlashBackup, in directory: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(backup.chip.stubName)-\(backup.flashSize >> 20)MB-\(stamp.string(from: backup.date)).bin"
        let url = directory.appendingPathComponent(name)
        try Data(backup.data).write(to: url)
        return url
    }

    /// `readLabels: false` returns at once with the labels already known; reading a label scans the whole 8 MB image.
    public static func list(in directory: URL = directory, readLabels: Bool = true) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "bin" }.compactMap { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count >= 4, let date = stamp.date(from: parts[parts.count - 2] + "-" + parts[parts.count - 1]) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let chip = ESPChip.allCases.first { $0.stubName == parts[0] }?.rawValue ?? String(parts[0])
            let firmware = readLabels ? labels.label(for: url, compute: describe) : (labels.cached(for: url) ?? nil)
            return Entry(url: url, chip: chip, date: date, size: size, firmware: firmware)
        }
        .sorted { $0.date > $1.date }
    }
}

public struct ESPFlashOptions: Sendable {
    public var baudRate = 460_800
    public var useStub = true
    public var backupFirst = true

    public init(baudRate: Int = 460_800, useStub: Bool = true, backupFirst: Bool = true) {
        self.baudRate = baudRate; self.useStub = useStub; self.backupFirst = backupFirst
    }
}

public struct ESPFlashImage: Sendable {
    public let name: String
    public let address: UInt32
    public let data: [UInt8]
    public let isApplication: Bool

    public init(name: String, address: UInt32, data: [UInt8], isApplication: Bool = true) {
        self.name = name; self.address = address; self.data = data; self.isApplication = isApplication
    }
}

public struct ESPFlashJob: Sendable {
    public var images: [ESPFlashImage]
    public var eraseAll: Bool

    public init(images: [ESPFlashImage], eraseAll: Bool = false) { self.images = images; self.eraseAll = eraseAll }

    /// Reads the flash into a backup and writes nothing.
    public static let backupOnly = ESPFlashJob(images: [])
    var isBackupOnly: Bool { images.isEmpty && !eraseAll }

    public static func single(_ data: Data, at address: UInt32 = 0, name: String = "image") -> ESPFlashJob {
        ESPFlashJob(images: [ESPFlashImage(name: name, address: address, data: [UInt8](data))])
    }

    var totalBytes: Int { images.reduce(0) { $0 + $1.data.count } }
}

public struct ESPFlasher: Flasher {
    public let portPath: String
    public let job: ESPFlashJob
    public let options: ESPFlashOptions
    private let openPort: @Sendable () throws -> ESPSerial
    private let onBackup: (@Sendable (ESPFlashBackup) throws -> Void)?
    private let logger: (@Sendable (String) -> Void)?

    public init(
        portPath: String, job: ESPFlashJob, options: ESPFlashOptions = .init(),
        openPort: (@Sendable () throws -> ESPSerial)? = nil,
        onBackup: (@Sendable (ESPFlashBackup) throws -> Void)? = { try FlashBackupStore.save($0) },
        logger: (@Sendable (String) -> Void)? = nil
    ) {
        self.portPath = portPath
        self.job = job
        self.options = options
        self.openPort = openPort ?? { try SerialPort(path: portPath) }
        self.onBackup = onBackup
        self.logger = logger
    }

    private var willBackUp: Bool { options.backupFirst && options.useStub && onBackup != nil }

    public var steps: [FlashStep] {
        var s = [FlashStep(id: "connect", title: "Enter the bootloader and detect the chip")]
        if willBackUp { s.append(FlashStep(id: "backup", title: job.isBackupOnly ? "Read the flash into a backup" : "Back up the current flash")) }
        if job.isBackupOnly { return s + [FlashStep(id: "reset", title: "Restart the board")] }
        if job.eraseAll { s.append(FlashStep(id: "erase", title: "Erase the flash")) }
        let writeTitle = job.images.count == 1 ? "Write the image" : "Write \(job.images.count) images"
        s += [FlashStep(id: "write", title: writeTitle),
              FlashStep(id: "verify", title: "Verify the written data"),
              FlashStep(id: "reset", title: "Restart the board")]
        return s
    }

    public func run(update: @escaping @Sendable (String, FlashStep.State) -> Void) async throws {
        let port = try openPort()
        let loader = ESPLoader(port: port, logger: logger)
        await loader.start()
        defer { Task { await loader.stop(); port.close() } }

        var currentStep = "connect"
        do {
            update("connect", .running(nil))
            try await loader.connect(strategies: ESPResetStrategy.sequence(forPortPath: portPath))
            let chip = try await loader.detectChip()
            if options.useStub {
                do { try await loader.runStub() } catch {
                    logger?("stub unavailable, continuing with the ROM loader: \(error.localizedDescription)")
                }
            }
            if options.baudRate > 115_200 { try await loader.changeBaudRate(options.baudRate) }
            try await loader.attachFlash()
            let flashID = try await loader.detectFlash()
            let flashSize = flashID.sizeBytes
            try await loader.setFlashParameters(size: flashSize ?? 4 << 20)
            for image in job.images {
                try ESPImageCheck.validate(image.data, at: image.address, chip: chip, flashSize: flashSize, isApplication: image.isApplication)
            }
            update("connect", .done)

            if willBackUp {
                currentStep = "backup"
                guard await loader.isStub, let flashSize else {
                    update("backup", .failed("Needs the flasher stub and a recognised flash size"))
                    throw ESPError.notInStubMode("Backing up the flash")
                }
                update("backup", .running(0))
                let data = try await loader.readFlash(offset: 0, length: flashSize) { update("backup", .running($0)) }
                try onBackup?(ESPFlashBackup(chip: chip, flashSize: flashSize, date: Date(), data: data))
                update("backup", .done)
            }

            if job.isBackupOnly {
                currentStep = "reset"
                update("reset", .running(nil))
                try await loader.hardReset()
                update("reset", .done)
                return
            }

            if job.eraseAll {
                currentStep = "erase"
                update("erase", .running(nil))
                if await loader.isStub { try await loader.eraseFlash() } else { logger?("no stub, so no full erase; writes erase their own regions") }
                update("erase", .done)
            }

            currentStep = "write"
            update("write", .running(0))
            let total = Double(max(job.totalBytes, 1))
            var written = 0.0
            for image in job.images {
                let base = written, weight = Double(image.data.count)
                try await loader.writeFlash(image.data, at: image.address, verify: false) { f in
                    update("write", .running((base + f * weight) / total))
                }
                written += weight
            }
            update("write", .done)

            currentStep = "verify"
            update("verify", .running(nil))
            for image in job.images { try await loader.verifyFlash(image.data, at: image.address) }
            update("verify", .done)

            currentStep = "reset"
            update("reset", .running(nil))
            try await loader.hardReset()
            update("reset", .done)
        } catch {
            update(currentStep, .failed(error.localizedDescription))
            throw error
        }
    }
}
