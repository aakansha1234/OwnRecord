import Foundation
import Observation

/// Calls `onChange` every time any observable property read inside `track` changes.
@MainActor
func observeContinuously(_ track: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
    withObservationTracking {
        track()
    } onChange: {
        Task { @MainActor in
            onChange()
            observeContinuously(track, onChange: onChange)
        }
    }
}
