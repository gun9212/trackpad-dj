import Foundation

/// The current set of active touches on the trackpad.
///
/// Immutable. All mutations return a new instance.
struct TouchSession {

    let activeTouches: [ObjectIdentifier: TouchPoint]

    static let empty = TouchSession(activeTouches: [:])

    func adding(_ touch: TouchPoint) -> TouchSession {
        var updated = activeTouches
        updated[touch.identity] = touch
        return TouchSession(activeTouches: updated)
    }

    func updating(_ touch: TouchPoint) -> TouchSession {
        // Only update if a touch with this identity is already tracked.
        guard activeTouches[touch.identity] != nil else { return self }
        var updated = activeTouches
        updated[touch.identity] = touch
        return TouchSession(activeTouches: updated)
    }

    func removing(identity: ObjectIdentifier) -> TouchSession {
        var updated = activeTouches
        updated.removeValue(forKey: identity)
        return TouchSession(activeTouches: updated)
    }

    var count: Int { activeTouches.count }
}
