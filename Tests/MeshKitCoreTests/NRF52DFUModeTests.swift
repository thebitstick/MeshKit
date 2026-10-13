import Foundation
import Testing
@testable import MeshKitCore

private final class Silent: ByteTransport, @unchecked Sendable {
    private let broadcaster = DataBroadcaster()
    func subscribe() -> AsyncStream<Data> { broadcaster.subscribe() }
    func send(_ data: Data) async throws {}
    func close() { broadcaster.finish() }
}

@Suite struct NRF52DFUModeTests {
    @Test func aMeshtasticNodeIsAskedToRestartIntoTheUF2Bootloader() async throws {
        let node = SimulatedMeshtasticNode()
        let touched = Locked(false)
        let outcome = try await NRF52DFUMode.enter(path: "/dev/cu.usbmodemFAKE", openPort: { node }, touch: { touched.value = true })
        #expect(outcome == .uf2Drive)
        #expect(node.dfuRequests == 1 && touched.value == false)
    }

    @Test func aNodeThatDoesNotAnswerGetsTheSerialDFUTouch() async throws {
        let touched = Locked(false)
        let outcome = try await NRF52DFUMode.enter(path: "/dev/cu.usbmodemFAKE", openPort: { Silent() }, touch: { touched.value = true })
        #expect(outcome == .serialDFU && touched.value)
    }

    @Test func aManagedNodeFallsBackToTheTouch() async throws {
        let node = SimulatedMeshtasticNode()
        node.setManaged(true)
        let touched = Locked(false)
        let outcome = try await NRF52DFUMode.enter(path: "/dev/cu.usbmodemFAKE", openPort: { node }, touch: { touched.value = true })
        #expect(outcome == .serialDFU && touched.value && node.dfuRequests == 0)
    }
}
