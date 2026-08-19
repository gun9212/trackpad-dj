import CoreGraphics
import XCTest
@testable import TrackpadDJ

final class CursorLockControllerTests: XCTestCase {

    @MainActor
    func testLockAndUnlockAreIdempotentAndBalanceHideCalls() throws {
        let system = FakeCursorSystem()
        let controller = CursorLockController(system: system)

        try controller.lock(windowIsKey: true, cursorInsideContent: true)
        try controller.lock(windowIsKey: true, cursorInsideContent: true)
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(system.calls, [.associate(false), .hide])

        try controller.unlock()
        try controller.unlock()
        XCTAssertFalse(controller.isLocked)
        XCTAssertEqual(system.calls, [
            .associate(false), .hide,
            .associate(true), .unhide,
        ])
    }

    @MainActor
    func testLockRequiresKeyWindowAndCursorInsideContent() {
        let system = FakeCursorSystem()
        let controller = CursorLockController(system: system)

        XCTAssertThrowsError(try controller.lock(
            windowIsKey: false,
            cursorInsideContent: true
        ))
        XCTAssertThrowsError(try controller.lock(
            windowIsKey: true,
            cursorInsideContent: false
        ))
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertFalse(controller.isLocked)
    }

    @MainActor
    func testFailedDisconnectImmediatelyRequestsRollbackWithoutHiding() {
        let system = FakeCursorSystem(associationResults: [.failure, .success])
        let controller = CursorLockController(system: system)

        XCTAssertThrowsError(try controller.lock(
            windowIsKey: true,
            cursorInsideContent: true
        ))
        XCTAssertEqual(system.calls, [.associate(false), .associate(true)])
        XCTAssertFalse(controller.isLocked)
    }

    @MainActor
    func testFailedReconnectStillBalancesCursorVisibility() throws {
        let system = FakeCursorSystem(associationResults: [.success, .failure])
        let controller = CursorLockController(system: system)
        try controller.lock(windowIsKey: true, cursorInsideContent: true)

        XCTAssertThrowsError(try controller.unlock())
        XCTAssertEqual(system.calls, [
            .associate(false), .hide,
            .associate(true), .unhide,
        ])
        XCTAssertFalse(controller.isLocked)
    }
}

@MainActor
private final class FakeCursorSystem: CursorSystemControlling {
    enum Call: Equatable {
        case associate(Bool)
        case hide
        case unhide
    }

    private var associationResults: [CGError]
    private(set) var calls: [Call] = []

    init(associationResults: [CGError] = []) {
        self.associationResults = associationResults
    }

    func associateMouseAndCursor(_ connected: Bool) -> CGError {
        calls.append(.associate(connected))
        guard !associationResults.isEmpty else { return .success }
        return associationResults.removeFirst()
    }

    func hideCursor() {
        calls.append(.hide)
    }

    func unhideCursor() {
        calls.append(.unhide)
    }
}
