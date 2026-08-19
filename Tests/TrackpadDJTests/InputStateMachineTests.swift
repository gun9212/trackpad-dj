import CoreGraphics
import XCTest
@testable import TrackpadDJ

final class InputStateMachineTests: XCTestCase {

    func testKeyboardTracksPressedSetCancelsOppositesAndClearsOnFocusLoss() {
        var keyboard = KeyboardStateMachine()

        XCTAssertEqual(
            keyboard.keyDown(keyCode: 12, isRepeat: false, shift: false),
            [.load(.a)]
        )
        XCTAssertEqual(
            keyboard.keyDown(keyCode: 12, isRepeat: true, shift: false),
            []
        )

        XCTAssertEqual(keyboard.keyDown(keyCode: 14, isRepeat: false, shift: false), [])
        XCTAssertEqual(keyboard.heldActions(), [.adjustVolume(.a, 0.008)])

        XCTAssertEqual(keyboard.keyDown(keyCode: 2, isRepeat: false, shift: false), [])
        XCTAssertEqual(keyboard.heldActions(), [])

        keyboard.keyUp(keyCode: 2)
        XCTAssertEqual(keyboard.heldActions(), [.adjustVolume(.a, 0.008)])

        keyboard.focusLost()
        XCTAssertTrue(keyboard.pressedKeys.isEmpty)
        XCTAssertEqual(keyboard.heldActions(), [])
    }

    func testTempoKeysRepeatAtFiveHundredthsPercentAndCancelOpposites() {
        var keyboard = KeyboardStateMachine()

        XCTAssertEqual(keyboard.keyDown(keyCode: 32, isRepeat: false, shift: false), [])
        XCTAssertEqual(keyboard.heldActions(), [.adjustTempo(.a, 0.05)])

        XCTAssertEqual(keyboard.keyDown(keyCode: 38, isRepeat: false, shift: false), [])
        XCTAssertEqual(keyboard.heldActions(), [])

        keyboard.keyUp(keyCode: 32)
        XCTAssertEqual(keyboard.heldActions(), [.adjustTempo(.a, -0.05)])
    }

    func testDiagonalMotionWaitsForDominanceThenLocksOneAxis() {
        var machine = GestureStateMachine()
        let id = TouchID(rawValue: 1)

        XCTAssertEqual(
            machine.process(.began([point(id, x: 0.25, y: 0.5, time: 0)])),
            [.setScratch(.a, 0)]
        )
        XCTAssertEqual(
            machine.process(.moved([point(id, x: 0.26, y: 0.51, time: 0.01)])),
            []
        )
        XCTAssertEqual(
            machine.process(.moved([point(id, x: 0.28, y: 0.51, time: 0.02)])),
            [.adjustFilter(.a, 0.02)]
        )
        XCTAssertEqual(
            machine.process(.moved([point(id, x: 0.28, y: 0.56, time: 0.03)])),
            []
        )
    }

    func testGestureKeepsStartingZoneAfterCrossingBoundary() {
        var machine = GestureStateMachine()
        let id = TouchID(rawValue: 1)
        _ = machine.process(.began([point(id, x: 0.49, y: 0.5, time: 0)]))

        XCTAssertEqual(
            machine.process(.moved([point(id, x: 0.51, y: 0.55, time: 0.01)])),
            [.setScratch(.a, 8.0)]
        )
        XCTAssertEqual(machine.process(.ended([id])), [.endScratch(.a)])
    }

    func testOnlyFirstTouchInZoneControlsAndSecondaryIsNotPromoted() {
        var machine = GestureStateMachine()
        let first = TouchID(rawValue: 1)
        let second = TouchID(rawValue: 2)

        XCTAssertEqual(
            machine.process(.began([
                point(second, x: 0.3, y: 0.4, time: 0),
                point(first, x: 0.2, y: 0.4, time: 0),
            ])),
            [.setScratch(.a, 0)]
        )
        XCTAssertEqual(
            machine.process(.moved([point(second, x: 0.3, y: 0.5, time: 0.01)])),
            []
        )
        XCTAssertEqual(machine.process(.ended([first])), [.endScratch(.a)])
        XCTAssertEqual(
            machine.process(.moved([point(second, x: 0.3, y: 0.6, time: 0.02)])),
            []
        )
    }

    func testStationaryScratchZerosAfterFiftyMillisecondsOnlyOnce() {
        var machine = GestureStateMachine()
        let id = TouchID(rawValue: 1)

        _ = machine.process(.began([point(id, x: 0.2, y: 0.4, time: 1.0)]))
        assertSingleScratch(
            machine.process(.moved([point(id, x: 0.2, y: 0.42, time: 1.01)])),
            deck: .a,
            rate: 6.6
        )
        XCTAssertEqual(machine.process(.tick(1.059)), [])
        XCTAssertEqual(machine.process(.tick(1.061)), [.setScratch(.a, 0)])
        XCTAssertEqual(machine.process(.tick(1.2)), [])
    }

    func testCancellationReleasesEveryControlledDeck() {
        var machine = GestureStateMachine()
        let deckA = TouchID(rawValue: 1)
        let deckB = TouchID(rawValue: 2)

        XCTAssertEqual(
            machine.process(.began([
                point(deckB, x: 0.75, y: 0.5, time: 0),
                point(deckA, x: 0.25, y: 0.5, time: 0),
            ])),
            [.setScratch(.a, 0), .setScratch(.b, 0)]
        )
        XCTAssertEqual(
            machine.process(.cancelled),
            [.endScratch(.a), .endScratch(.b)]
        )
        XCTAssertEqual(machine.session, .empty)
    }

    func testTraceReplayIsDeterministic() {
        let id = TouchID(rawValue: 1)
        let trace: [GestureInputEvent] = [
            .began([point(id, x: 0.25, y: 0.5, time: 3.0)]),
            .moved([point(id, x: 0.25, y: 0.52, time: 3.01)]),
            .tick(3.07),
            .ended([id]),
        ]

        let firstReplay = replay(trace)
        XCTAssertEqual(firstReplay, replay(trace))
        XCTAssertEqual(firstReplay.count, 4)
        XCTAssertEqual(firstReplay[0], .setScratch(.a, 0))
        assertSingleScratch([firstReplay[1]], deck: .a, rate: 6.6)
        XCTAssertEqual(firstReplay[2], .setScratch(.a, 0))
        XCTAssertEqual(firstReplay[3], .endScratch(.a))
    }

    private func replay(_ trace: [GestureInputEvent]) -> [DJAction] {
        var machine = GestureStateMachine()
        return trace.flatMap { machine.process($0) }
    }

    private func point(
        _ identity: TouchID,
        x: CGFloat,
        y: CGFloat,
        time: TimeInterval
    ) -> TouchPoint {
        TouchPoint(
            identity: identity,
            position: CGPoint(x: x, y: y),
            timestamp: time
        )
    }

    private func assertSingleScratch(
        _ actions: [DJAction],
        deck expectedDeck: DeckID,
        rate expectedRate: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard actions.count == 1,
              case .setScratch(let actualDeck, let actualRate) = actions[0] else {
            XCTFail("Expected one scratch action, got \(actions)", file: file, line: line)
            return
        }
        XCTAssertEqual(actualDeck, expectedDeck, file: file, line: line)
        XCTAssertEqual(actualRate, expectedRate, accuracy: 0.000_001, file: file, line: line)
    }
}
