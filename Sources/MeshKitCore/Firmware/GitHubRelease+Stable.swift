import Foundation

extension GitHubRelease {
    public var isStable: Bool { !prerelease }
}
