import Foundation

public protocol ByteTransport: AnyObject, Sendable {
    func subscribe() -> AsyncStream<Data>
    func send(_ data: Data) async throws
    func close()
}

public final class DataBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock(); subscribers[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock(); self?.subscribers[id] = nil; self?.lock.unlock()
            }
        }
    }

    public func yield(_ data: Data) {
        lock.lock(); let subs = Array(subscribers.values); lock.unlock()
        for s in subs { s.yield(data) }
    }

    public func finish() {
        lock.lock(); let subs = Array(subscribers.values); subscribers.removeAll(); lock.unlock()
        for s in subs { s.finish() }
    }
}

// MARK: - Real serial port

public enum SerialError: Error, LocalizedError {
    case openFailed(String, Int32)
    case writeFailed(Int32)
    case closed

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let e): "Could not open \(path): \(String(cString: strerror(e)))"
        case .writeFailed(let e): "Serial write failed: \(String(cString: strerror(e)))"
        case .closed: "Port is closed"
        }
    }
}

public struct SerialPortInfo: Identifiable, Hashable, Sendable {
    public let path: String
    public var id: String { path }

    public var displayName: String {
        String(path.dropFirst("/dev/cu.".count))
    }

    /// Rough guess from the device node name; real VID/PID lookup via IOKit is a TODO.
    public var hint: String {
        if path.contains("usbmodem") { return "Native USB (CDC)" }
        if path.contains("SLAB") || path.contains("usbserial") { return "USB-UART bridge" }
        if path.contains("wchusbserial") { return "CH34x bridge" }
        return "Serial"
    }
}

public enum SerialDiscovery {
    public static func list() -> [SerialPortInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") && ["usbmodem", "usbserial", "wchusbserial", "SLAB_USBtoUART"].contains(where: $0.contains) }
            .sorted()
            .map { SerialPortInfo(path: "/dev/" + $0) }
    }
}

public final class SerialPort: ByteTransport, @unchecked Sendable {
    public let path: String
    private let fd: Int32
    var fileDescriptor: Int32 { fd }
    var isClosedPort: Bool { lock.withLock { isClosed } }
    private var source: DispatchSourceRead?
    private let broadcaster = DataBroadcaster()
    private let writeQueue = DispatchQueue(label: "meshkit.serial.write")
    private var isClosed = false
    private let lock = NSLock()

    public init(path: String, baud: Int = 115_200) throws {
        self.path = path
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.openFailed(path, errno) }
        self.fd = fd

        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(baud))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(HUPCL)   // don't drop DTR on close; avoids an extra board reset
        tcsetattr(fd, TCSANOW, &t)
        tcflush(fd, TCIOFLUSH)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { Darwin.close(fd) }
        source = src
        src.resume()
    }

    deinit { close() }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            broadcaster.yield(Data(buf[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            close()
        }
    }

    public func subscribe() -> AsyncStream<Data> { broadcaster.subscribe() }

    public func send(_ data: Data) async throws {
        guard !isClosedPort else { throw SerialError.closed }
        let bytes = [UInt8](data)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writeQueue.async { [fd] in
                var offset = 0
                while offset < bytes.count {
                    let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                    if n < 0 {
                        if errno == EAGAIN || errno == EINTR { usleep(2_000); continue }
                        c.resume(throwing: SerialError.writeFailed(errno)); return
                    }
                    offset += n
                }
                c.resume()
            }
        }
    }

    public func close() {
        let alreadyClosed = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return isClosed
        }
        guard !alreadyClosed else { return }
        source?.cancel()
        source = nil
        broadcaster.finish()
    }
}
