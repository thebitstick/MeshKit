import Foundation

/// Remembers what each saved image was named after reading it, keyed by path and modification time, so a list can be shown
/// at once and labelled in the background.
final class LabelCache: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String: String?] = [:]

    private func key(_ url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return "\(url.path)|\(modified.timeIntervalSince1970)"
    }

    /// `.some(nil)` means "read it, nothing recognisable"; `nil` means "not read yet".
    func cached(for url: URL) -> String?? {
        lock.lock(); defer { lock.unlock() }
        return labels[key(url)]
    }

    func label(for url: URL, compute: (Data) -> String?) -> String? {
        if let known = cached(for: url) { return known }
        let value = (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(compute)
        lock.lock(); labels[key(url)] = .some(value); lock.unlock()
        return value
    }
}
