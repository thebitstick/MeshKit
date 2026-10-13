import Foundation
import Testing
@testable import MeshKitCore

@Suite struct DownloadSafetyTests {
    @Test func releaseDataCanNeverEscapeTheCacheDirectory() {
        for hostile in ["../../../../etc/passwd", "..", "../x", "a/b/c", "/abs/path", "..\\..\\win", ".hidden", "...", "", "  ", "name:with:colons", "a/../../b"] {
            let safe = ReleaseClient.safeComponent(hostile)
            #expect(!safe.contains("/") && !safe.contains("\\") && !safe.contains("..") && !safe.contains(":"), "\(hostile) -> \(safe)")
            #expect(!safe.isEmpty && !safe.hasPrefix("."), "\(hostile) -> \(safe)")
        }
        #expect(ReleaseClient.safeComponent("Heltec_v3_companion_radio_usb-v1.17.1-d929643-merged.bin") == "Heltec_v3_companion_radio_usb-v1.17.1-d929643-merged.bin")
        #expect(ReleaseClient.safeComponent("companion-v1.17.1") == "companion-v1.17.1")
        #expect(ReleaseClient.safeComponent("beta_89") == "beta_89")
        #expect(ReleaseClient.safeComponent(String(repeating: "a", count: 500)).count == 200)
    }
}
