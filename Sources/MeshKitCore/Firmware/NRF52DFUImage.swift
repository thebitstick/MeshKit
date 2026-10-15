import Foundation

/// The SoftDevice (Nordic's Bluetooth stack) an nRF52 board runs, as identified by its firmware ID. The bootloader's DFU
/// only replaces the application, which starts where the SoftDevice ends.
public enum NRF52SoftDevice {
    /// The generation Meshtastic's erase tools are built for: "7.3" or "6.1".
    public static func series(forFirmwareID id: UInt16) -> String? {
        switch id {
        case 0x123: "7.3"
        case 0xA9, 0xAE, 0xB6: "6.1"
        default: nil
        }
    }

    public struct Info: Equatable, Sendable {
        public let firmwareID: UInt16
        /// Where the SoftDevice ends, which is where the application begins.
        public let size: UInt32
    }

    static let infoMagic: UInt32 = 0x51B1E5DB

    /// Reads the SoftDevice information block (magic at 0x3004, then size and firmware ID) from a flash image's pages.
    static func info(in pages: [UInt32: Data]) -> Info? {
        func word(_ address: UInt32) -> UInt32? {
            let page = address & ~255
            guard let data = pages[page], Int(address - page) + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Int(address - page), as: UInt32.self) }
        }
        guard word(0x3004) == infoMagic, let size = word(0x3008), let id = word(0x300C) else { return nil }
        return Info(firmwareID: UInt16(truncatingIfNeeded: id), size: size)
    }
}

extension NRF52DFUPackage {
    public enum ImageError: LocalizedError {
        case notAUF2, noSoftDevice, unexpectedStart(UInt32, UInt32), noApplication, unknownSoftDevice([UInt16])
        public var errorDescription: String? {
            switch self {
            case .notAUF2: "That isn't a UF2 file."
            case .noSoftDevice: "This image has no Bluetooth stack in it, so MeshKit can't tell where the application starts."
            case .unexpectedStart(let found, let expected): "The application starts at 0x\(String(found, radix: 16)), not 0x\(String(expected, radix: 16)), so it isn't built for this board's Bluetooth stack."
            case .noApplication: "This image has no application in it."
            case .unknownSoftDevice(let ids): "MeshKit doesn't know the Bluetooth stack this firmware needs (\(ids.map { "0x" + String($0, radix: 16) }.joined(separator: ", "))), so it can't choose the matching erase tool."
            }
        }
    }

    /// A DFU package for an application: Nordic's legacy init packet (device type 0x52, any revision and version, the
    /// SoftDevice it needs, the CRC-16 of the image).
    public init(application: Data, softDevice id: UInt16) {
        var packet: [UInt8] = [0x52, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00, UInt8(id & 0xFF), UInt8(id >> 8)]
        let crc = NRF52HCI.crc16([UInt8](application))
        packet += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        self.init(initPacket: Data(packet), firmware: application)
    }

    /// The SoftDevices the package says it needs (`0xFFFE` means any).
    public var softDevices: [UInt16] {
        let p = [UInt8](initPacket)
        guard p.count >= 10 else { return [] }
        let count = Int(p[8]) | Int(p[9]) << 8
        guard p.count >= 10 + count * 2 else { return [] }
        return (0..<count).map { UInt16(p[10 + 2 * $0]) | UInt16(p[11 + 2 * $0]) << 8 }
    }

    static func pages(ofUF2 data: Data) throws -> [UInt32: Data] {
        guard data.count >= 512, data.count % 512 == 0 else { throw ImageError.notAUF2 }
        var pages: [UInt32: Data] = [:]
        var offset = 0
        while offset < data.count {
            let block = data.subdata(in: offset..<offset + 512)
            offset += 512
            let magic = block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            guard magic == UF2.magicStart0 else { throw ImageError.notAUF2 }
            let address = block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
            let size = Int(block.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) })
            guard size <= 476 else { throw ImageError.notAUF2 }
            pages[address] = block.subdata(in: 32..<32 + size)
        }
        return pages
    }

    /// The application part of a bootloader's `CURRENT.UF2`, for putting a saved firmware back over serial DFU. The
    /// SoftDevice stays as it is on the board; its ID tells the bootloader which one the image was built for.
    public static func restoring(backup uf2: Data) throws -> NRF52DFUPackage {
        let pages = try Self.pages(ofUF2: uf2)
        guard let info = NRF52SoftDevice.info(in: pages) else { throw ImageError.noSoftDevice }
        let app = try application(from: pages, startingAt: info.size)
        return NRF52DFUPackage(application: app, softDevice: info.firmwareID)
    }

    /// An application-only UF2 (such as Meshtastic's erase tools) as a DFU package for the given SoftDevice's generation.
    public static func application(fromUF2 uf2: Data, startingAt start: UInt32, softDevice id: UInt16) throws -> NRF52DFUPackage {
        let pages = try Self.pages(ofUF2: uf2)
        guard let lowest = pages.keys.min() else { throw ImageError.noApplication }
        guard lowest == start else { throw ImageError.unexpectedStart(lowest, start) }
        return NRF52DFUPackage(application: try application(from: pages, startingAt: start), softDevice: id)
    }

    private static func application(from pages: [UInt32: Data], startingAt start: UInt32) throws -> Data {
        let addresses = pages.keys.filter { $0 >= start }.sorted()
        guard let last = addresses.last, let lastPage = pages[last] else { throw ImageError.noApplication }
        var image = Data(repeating: 0xFF, count: Int(last - start) + lastPage.count)
        for address in addresses {
            let page = pages[address]!
            image.replaceSubrange(Int(address - start)..<Int(address - start) + page.count, with: page)
        }
        return image
    }

    /// Where the application starts for a SoftDevice generation, which is also where Meshtastic's erase tool for it starts.
    static func applicationStart(forSeries series: String) -> UInt32? {
        switch series {
        case "7.3": 0x27000
        case "6.1": 0x26000
        default: nil
        }
    }

    /// The erase tool for the SoftDevice generation this firmware package was built for, as a DFU package.
    public static func eraseTool(for firmware: NRF52DFUPackage, from images: NRF52EraseImages) throws -> NRF52DFUPackage {
        let ids = firmware.softDevices
        let series = Set(ids.compactMap(NRF52SoftDevice.series(forFirmwareID:)))
        guard series.count == 1, let one = series.first, let start = applicationStart(forSeries: one),
              let image = images.images[one], let id = ids.first(where: { NRF52SoftDevice.series(forFirmwareID: $0) == one }) else {
            throw ImageError.unknownSoftDevice(ids)
        }
        return try application(fromUF2: image, startingAt: start, softDevice: id)
    }
}
