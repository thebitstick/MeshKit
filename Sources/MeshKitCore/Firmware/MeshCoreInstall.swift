import Foundation

public enum MeshCoreInstallMode: String, CaseIterable, Identifiable, Sendable {
    case update = "Update"
    case fresh = "Clean install"

    public var id: String { rawValue }
    public var blurb: String {
        switch self {
        case .update: "Keeps your settings and identity."
        case .fresh: "Erases everything first. For new or broken boards. Identity key and settings are lost."
        }
    }
}

public struct ESPPartition: Sendable, Equatable {
    public let name: String
    public let type: UInt8
    public let subtype: UInt8
    public let offset: Int
    public let size: Int
}

public enum ESPPartitionTable {
    public static let flashOffset = 0x8000

    public static func parse(image: [UInt8]) -> [ESPPartition] {
        var out: [ESPPartition] = []
        var at = flashOffset
        while at + 32 <= image.count, image[at] == 0xAA, image[at + 1] == 0x50 {
            func le32(_ i: Int) -> Int { Int(image[i]) | Int(image[i + 1]) << 8 | Int(image[i + 2]) << 16 | Int(image[i + 3]) << 24 }
            let name = String(decoding: image[(at + 12)..<(at + 28)].prefix { $0 != 0 }, as: UTF8.self)
            out.append(ESPPartition(name: name, type: image[at + 2], subtype: image[at + 3], offset: le32(at + 4), size: le32(at + 8)))
            at += 32
        }
        return out
    }
}

public enum MeshCoreInstallError: LocalizedError {
    case unreadableLayout

    public var errorDescription: String? {
        "MeshKit couldn't read this image's partition layout, so it can't do an update that keeps settings. Use a clean install instead."
    }
}

public enum MeshCoreImage {
    /// A clean install writes the full image at 0x0 after erasing the chip.
    public static func cleanJob(merged: Data, name: String) -> ESPFlashJob {
        var job = ESPFlashJob.single(merged, name: name)
        job.eraseAll = true
        return job
    }

    /// An update rewrites only the boot-selection data and the application, so the settings and identity stored in the
    /// filesystem partition survive. The application bytes come from the merged image (they are identical to the
    /// separate app-only file), and the layout is read from the partition table inside it.
    public static func updateJob(merged: Data, name: String) throws -> ESPFlashJob {
        let bytes = [UInt8](merged)
        let table = ESPPartitionTable.parse(image: bytes)
        guard let app = table.first(where: { $0.type == 0 && ($0.subtype == 0x00 || $0.subtype == 0x10) }),
              let ota = table.first(where: { $0.type == 1 && $0.subtype == 0x00 }),
              ota.offset + ota.size <= app.offset, app.offset < bytes.count, bytes[app.offset] == ESPImageCheck.imageMagic
        else { throw MeshCoreInstallError.unreadableLayout }
        return ESPFlashJob(images: [
            ESPFlashImage(name: "otadata", address: UInt32(ota.offset), data: Array(bytes[ota.offset..<(ota.offset + ota.size)]), isApplication: false),
            ESPFlashImage(name: name, address: UInt32(app.offset), data: Array(bytes[app.offset...])),
        ])
    }
}
