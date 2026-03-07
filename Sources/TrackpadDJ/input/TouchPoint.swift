import CoreGraphics
import Foundation

/// A single touch contact captured at a specific moment in time.
///
/// Immutable. Use the `moving(to:)` helper to produce an updated copy.
struct TouchPoint {

    /// Stable identifier for this touch across begin / moved / ended phases.
    let identity: ObjectIdentifier

    /// Normalized trackpad position in [0, 1] × [0, 1].
    /// Origin is at the lower-left corner of the trackpad.
    let position: CGPoint

    let timestamp: TimeInterval

    /// Returns a new TouchPoint with an updated position and timestamp.
    func moving(to newPosition: CGPoint, at newTimestamp: TimeInterval) -> TouchPoint {
        TouchPoint(identity: identity, position: newPosition, timestamp: newTimestamp)
    }
}
