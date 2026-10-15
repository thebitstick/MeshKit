import Foundation

public enum UF2Error: Error, LocalizedError {
    case badSize(Int)
    case badMagic(block: Int)
    case empty
    case volumeGone
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badSize(let n): "File size \(n) is not a multiple of 512, so it is not a UF2 file"
        case .badMagic(let b): "Block \(b) is not a valid UF2 block"
        case .empty: "The UF2 file contains no blocks"
        case .volumeGone: "The bootloader volume disappeared before the write finished"
        case .writeFailed(let s): "Could not write to the bootloader volume: \(s)"
        }
    }
}

public struct UF2Info: Equatable, Sendable {
    public var blockCount: Int
    public var payloadBytes: Int
    public var familyID: UInt32?
    public var lowestAddress: UInt32
    public var highestAddress: UInt32

    public var familyName: String {
        guard let familyID else { return "none" }
        return UF2.knownFamilies[familyID] ?? String(format: "unknown (0x%08X)", familyID)
    }

    public var isNRF52: Bool { familyID == 0xADA52840 || familyID == 0x1B57745F }
}

public enum UF2 {
    static let magicStart0: UInt32 = 0x0A324655
    static let magicStart1: UInt32 = 0x9E5D5157
    static let magicEnd: UInt32 = 0x0AB16F30
    static let familyFlag: UInt32 = 0x2000

    public static let knownFamilies: [UInt32: String] = [
        0xADA52840: "nRF52840",
        0x1B57745F: "nRF52",
        0xE48BFF56: "RP2040",
        0x1C5F21B0: "ESP32",
        0xBFDD4EEE: "ESP32-S2",
        0xC47E5767: "ESP32-S3",
    ]

    public static func inspect(_ data: Data) throws -> UF2Info {
        guard data.count % 512 == 0 else { throw UF2Error.badSize(data.count) }
        guard !data.isEmpty else { throw UF2Error.empty }
        let bytes = [UInt8](data)
        var family: UInt32?
        var low = UInt32.max, high: UInt32 = 0, payload = 0
        for block in 0..<(bytes.count / 512) {
            var r = ByteReader(Array(bytes[block * 512..<block * 512 + 512]))
            let m0 = try r.u32(), m1 = try r.u32(), flags = try r.u32()
            let target = try r.u32(), size = try r.u32()
            _ = try r.u32(); _ = try r.u32()
            let familyOrSize = try r.u32()
            _ = try r.take(476, "data")
            let end = try r.u32()
            guard m0 == magicStart0, m1 == magicStart1, end == magicEnd else { throw UF2Error.badMagic(block: block) }
            if flags & familyFlag != 0 { family = familyOrSize }
            low = min(low, target)
            high = max(high, target &+ size)
            payload += Int(size)
        }
        return UF2Info(blockCount: bytes.count / 512, payloadBytes: payload, familyID: family,
                       lowestAddress: low, highestAddress: high)
    }
}

// MARK: - Bootloader volumes

public struct UF2Volume: Identifiable, Hashable, Sendable {
    public let url: URL
    public let model: String
    public let boardID: String
    public let bootloader: String
    public let softDevice: String

    public init(url: URL, model: String, boardID: String, bootloader: String, softDevice: String = "") {
        self.url = url; self.model = model; self.boardID = boardID; self.bootloader = bootloader; self.softDevice = softDevice
    }

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

public enum UF2Volumes {
    /// A bootloader drive is a tiny external disk (they report a few megabytes). Anything bigger, or internal, is never
    /// opened: reading a file on an external disk makes macOS ask the person for permission, and a person's own drives are
    /// none of this app's business.
    static let largestBootloaderDrive = 512 << 20

    public static func detect(volumesRoot: URL = URL(fileURLWithPath: "/Volumes"), bootloaderSizedOnly: Bool = true) -> [UF2Volume] {
        let keys: [URLResourceKey] = [.volumeTotalCapacityKey, .volumeIsInternalKey, .volumeIsLocalKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: volumesRoot, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { url in
            guard bootloaderSizedOnly else { return true }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsInternal != true, values?.volumeIsLocal != false,
                  let capacity = values?.volumeTotalCapacity, capacity > 0, capacity <= largestBootloaderDrive else { return false }
            return true
        }
        .compactMap { url in
            let info = url.appendingPathComponent("INFO_UF2.TXT")
            guard let text = try? String(contentsOf: info, encoding: .utf8) else { return nil }
            return parse(infoText: text, url: url)
        }
    }

    static func parse(infoText: String, url: URL) -> UF2Volume {
        let lines = infoText.split(whereSeparator: \.isNewline).map(String.init)
        func field(_ key: String) -> String {
            lines.first { $0.hasPrefix(key + ":") }
                .map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        return UF2Volume(url: url, model: field("Model"), boardID: field("Board-ID"), bootloader: lines.first ?? "", softDevice: field("SoftDevice"))
    }
}

public enum UF2Flasher {
    public enum Outcome: Sendable {
        case rebooted
        case volumeStillMounted
    }

    /// Copies the image to the volume as `NEW.UF2` in block-aligned chunks. The write is
    /// deliberately non-atomic: bootloaders flash as blocks arrive and reboot after the last one.
    public static func flash(
        image: Data,
        to volume: UF2Volume,
        progress: @Sendable (Double) -> Void
    ) async throws -> Outcome {
        _ = try UF2.inspect(image)
        let target = volume.url.appendingPathComponent("NEW.UF2")
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw UF2Error.writeFailed("could not create NEW.UF2")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: target) } catch { throw UF2Error.writeFailed(error.localizedDescription) }

        let chunk = 512 * 8
        var offset = 0
        do {
            while offset < image.count {
                let end = min(offset + chunk, image.count)
                try handle.write(contentsOf: image[offset..<end])
                offset = end
                progress(Double(offset) / Double(image.count))
                await Task.yield()
            }
            try handle.close()
        } catch {
            // The bootloader can unmount mid-close once it has the last block.
            if !FileManager.default.fileExists(atPath: volume.url.path), offset >= image.count - chunk { return .rebooted }
            try? handle.close()
            throw UF2Error.writeFailed(error.localizedDescription)
        }

        for _ in 0..<40 {
            if !FileManager.default.fileExists(atPath: volume.url.path) { return .rebooted }
            try await Task.sleep(for: .milliseconds(250))
        }
        return .volumeStillMounted
    }

    public static func readCurrentImage(from volume: UF2Volume) throws -> Data {
        try Data(contentsOf: volume.url.appendingPathComponent("CURRENT.UF2"))
    }
}
