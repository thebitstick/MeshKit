import Foundation

/// Makes every request through `URLSession.shared` fail the way a missing connection does, to see what the app does
/// without a network. Turned on with `MESHKIT_OFFLINE=1` or the `--offline` launch argument.
public final class OfflineSimulation: URLProtocol {
    public static var requested: Bool {
        ProcessInfo.processInfo.environment["MESHKIT_OFFLINE"] != nil || ProcessInfo.processInfo.arguments.contains("--offline")
    }

    public static func enableIfRequested() {
        if requested { URLProtocol.registerClass(OfflineSimulation.self) }
    }

    public override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme?.hasPrefix("http") == true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    public override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    public override func stopLoading() {}
}
