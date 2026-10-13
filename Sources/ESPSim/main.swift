import Foundation
import MeshKitCore

// A simulated device served over TCP so reference tools can talk to it. By default an ESP in its serial
// bootloader; with --meshtastic, a Meshtastic node speaking the stream API (default port 4403):
//
//   swift run esp-sim --meshtastic --port 4403
//   meshtastic --host 127.0.0.1 --info
//
// The ESP mode:
//
//   swift run esp-sim --port 5555 --chip esp32s3 --flash-mb 8 --dump /tmp/flash.bin
//   esptool --port socket://127.0.0.1:5555 --before no_reset --after no_reset chip_id
//
// When the client disconnects, the simulated flash is written to --dump (if given).

let traceConnections = ProcessInfo.processInfo.environment["MESHKIT_SIM_TRACE"] != nil
func trace(_ s: String) { if traceConnections { print("sim conn: \(s)"); fflush(stdout) } }
signal(SIGPIPE, SIG_IGN)   // clients disconnect abruptly; a write to a closed socket must not kill the server

var port: UInt16 = 5555
var chip = ESPChip.esp32s3
var flashMB = 8
var dumpPath: String?
var cmdLogPath: String?
var meshtasticMode = false

var args = CommandLine.arguments.dropFirst()
while let flag = args.popFirst() {
    switch flag {
    case "--port": port = UInt16(args.popFirst() ?? "") ?? port
    case "--chip":
        let name = args.popFirst() ?? ""
        chip = ESPChip.allCases.first { $0.stubName == name } ?? chip
    case "--meshtastic": meshtasticMode = true
    case "--flash-mb": flashMB = Int(args.popFirst() ?? "") ?? flashMB
    case "--dump": dumpPath = args.popFirst()
    case "--cmdlog": cmdLogPath = args.popFirst()
    default: FileHandle.standardError.write(Data("unknown option \(flag)\n".utf8)); exit(2)
    }
}

let esp = SimulatedESPDevice(chip: chip, flashSize: flashMB << 20, startInBootloader: true)
let node = SimulatedMeshtasticNode()
let sim: ByteTransport = meshtasticMode ? node : esp

let server = socket(AF_INET, SOCK_STREAM, 0)
var yes: Int32 = 1
setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
guard bound == 0, listen(server, 4) == 0 else { perror("bind/listen"); exit(1) }
print(meshtasticMode ? "esp-sim: Meshtastic node, listening on 127.0.0.1:\(port)" : "esp-sim: \(chip.rawValue), \(flashMB) MB flash, listening on 127.0.0.1:\(port)")
fflush(stdout)

while true {
    let client = accept(server, nil, nil)
    guard client >= 0 else { perror("accept"); exit(1) }
    trace("accepted fd \(client)")
    if !meshtasticMode { esp.resetToROM() }

    let outgoing = sim.subscribe()
    let writer = Task {
        for await chunk in outgoing {
            var offset = 0
            let bytes = [UInt8](chunk)
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                if n <= 0 { trace("write failed errno \(errno)"); return }
                offset += n
            }
        }
    }

    let (incoming, incomingSink) = AsyncStream.makeStream(of: Data.self)
    let reader = Task {
        for await chunk in incoming { try? await sim.send(chunk) }
    }

    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(client, &buf, buf.count)
            if n < 0, errno == EINTR || errno == EAGAIN { continue }
            if n <= 0 { trace("read returned \(n) errno \(errno)"); break }
            trace("read \(n) bytes")
            incomingSink.yield(Data(buf[0..<n]))
        }
        incomingSink.finish()
        done.signal()
    }
    done.wait()
    Thread.sleep(forTimeInterval: 0.3)
    writer.cancel(); reader.cancel()
    close(client)
    if let cmdLogPath, !meshtasticMode {
        let lines = esp.commands.map { c in
            String(format: "%02x %d ", c.op, c.data.count) + c.data.prefix(64).map { String(format: "%02x", $0) }.joined()
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: cmdLogPath, atomically: true, encoding: .utf8)
        esp.clearCommandLog()
    }
    if let dumpPath, !meshtasticMode {
        do { try Data(esp.flashContents).write(to: URL(fileURLWithPath: dumpPath)); print("esp-sim: flash written to \(dumpPath)") }
        catch { print("esp-sim: could not write \(dumpPath): \(error)") }
    }
    print("esp-sim: client disconnected")
    fflush(stdout)
}
