import AppKit
import CoreGraphics

@MainActor
protocol CursorSystemControlling {
    func associateMouseAndCursor(_ connected: Bool) -> CGError
    func hideCursor()
    func unhideCursor()
}

@MainActor
struct SystemCursorController: CursorSystemControlling {
    func associateMouseAndCursor(_ connected: Bool) -> CGError {
        CGAssociateMouseAndMouseCursorPosition(connected ? 1 : 0)
    }

    func hideCursor() {
        NSCursor.hide()
    }

    func unhideCursor() {
        NSCursor.unhide()
    }
}

enum CursorLockError: LocalizedError {
    case windowIsNotKey
    case cursorOutsideContent
    case associationFailed(CGError)
    case reassociationFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .windowIsNotKey:
            return "Cursor lock requires the Trackpad DJ window to be active."
        case .cursorOutsideContent:
            return "Move the cursor inside the Trackpad DJ window before locking it."
        case .associationFailed(let error):
            return "Cursor lock failed (Core Graphics error \(error.rawValue))."
        case .reassociationFailed(let error):
            return "Cursor restore failed (Core Graphics error \(error.rawValue))."
        }
    }
}

/// Balances each successful cursor hide with exactly one unhide.
@MainActor
final class CursorLockController {
    private let system: any CursorSystemControlling
    private(set) var isLocked = false

    init() {
        system = SystemCursorController()
    }

    init(system: any CursorSystemControlling) {
        self.system = system
    }

    func lock(windowIsKey: Bool, cursorInsideContent: Bool) throws {
        guard !isLocked else { return }
        guard windowIsKey else { throw CursorLockError.windowIsNotKey }
        guard cursorInsideContent else { throw CursorLockError.cursorOutsideContent }

        let result = system.associateMouseAndCursor(false)
        guard result == .success else {
            _ = system.associateMouseAndCursor(true)
            throw CursorLockError.associationFailed(result)
        }

        system.hideCursor()
        isLocked = true
    }

    func unlock() throws {
        guard isLocked else { return }

        let result = system.associateMouseAndCursor(true)
        system.unhideCursor()
        isLocked = false

        guard result == .success else {
            throw CursorLockError.reassociationFailed(result)
        }
    }
}
