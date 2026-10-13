import Combine
import Foundation
import Observation

/// Re-publishes `@Observable` changes through `ObservableObject`.
///
/// SwiftUI's `Commands` bodies don't track Observation, so a menu reading an `@Observable` model never
/// refreshes. Hold one of these in the `Commands` struct with `@ObservedObject`; `track` should read every
/// property the menus depend on.
@MainActor
public final class ObservationBridge: ObservableObject {
    private let readTracked: @MainActor () -> Void

    public init(track: @escaping @MainActor () -> Void) {
        readTracked = track
        arm()
    }

    /// Observation notifies once per registration, so re-arm after every change.
    private func arm() {
        withObservationTracking {
            readTracked()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.objectWillChange.send()
                self?.arm()
            }
        }
    }
}
