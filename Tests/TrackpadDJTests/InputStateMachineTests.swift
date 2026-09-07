import CoreGraphics
import XCTest
@testable import TrackpadDJ

final class InputStateMachineTests: XCTestCase {

    func testKeyboardDefaultsToDeckAAndTabSwitchesSharedCommands() {
        var keyboard = KeyboardStateMachine()

        XCTAssertEqual(keyboard.activeDeck, .a)
        XCTAssertEqual(keyboard.keyDown(keyCode: 12, isRepeat: false, shift: false), [.load(.a)])
        keyboard.keyUp(keyCode: 12)

        XCTAssertEqual(
            keyboard.keyDown(keyCode: 48, isRepeat: false, shift: false),
            [.selectActiveDeck(.b)]
        )
        XCTAssertEqual(keyboard.activeDeck, .b)
        keyboard.keyUp(keyCode: 48)

        XCTAssertEqual(
            keyboard.keyDown(keyCode: 49, isRepeat: false, shift: false),
            [.togglePlay(.b)]
        )
        keyboard.keyUp(keyCode: 49)
        XCTAssertEqual(
            keyboard.keyDown(keyCode: 11, isRepeat: false, shift: true),
            [.restoreAutomaticBPM(.b)]
        )
    }

    func testHeldKeysRemainPinnedToStartingDeckAcrossTab() {
        var keyboard = KeyboardStateMachine()

        XCTAssertEqual(keyboard.keyDown(keyCode: 14, isRepeat: false, shift: false), [])
        XCTAssertEqual(keyboard.heldActions(), [.adjustVolume(.a, 0.008)])

        XCTAssertEqual(
            keyboard.keyDown(keyCode: 48, isRepeat: false, shift: false),
            [.selectActiveDeck(.b)]
        )
        keyboard.keyUp(keyCode: 48)
        XCTAssertEqual(keyboard.heldActions(), [.adjustVolume(.a, 0.008)])

        XCTAssertEqual(keyboard.keyDown(keyCode: 2, isRepeat: false, shift: false), [])
        XCTAssertEqual(
            keyboard.heldActions(),
            [.adjustVolume(.a, 0.008), .adjustVolume(.b, -0.008)]
        )

        keyboard.focusLost()
        XCTAssertTrue(keyboard.pressedKeys.isEmpty)
        XCTAssertEqual(keyboard.heldActions(), [])
    }

    func testHeldTempoRepeatsAtFiveHundredthsAndOppositesCancelPerDeck() {
        var keyboard = KeyboardStateMachine()

        _ = keyboard.keyDown(keyCode: 17, isRepeat: false, shift: false)
        XCTAssertEqual(keyboard.heldActions(), [.adjustTempo(.a, 0.05)])
        _ = keyboard.keyDown(keyCode: 5, isRepeat: false, shift: false)
        XCTAssertEqual(keyboard.heldActions(), [])

        keyboard.keyUp(keyCode: 17)
        XCTAssertEqual(keyboard.heldActions(), [.adjustTempo(.a, -0.05)])
    }

    func testGlobalCrossfaderKeyDoesNotChangeActiveDeck() {
        var keyboard = KeyboardStateMachine()

        XCTAssertEqual(
            keyboard.keyDown(keyCode: 123, isRepeat: false, shift: false),
            [.stepCrossfader(-1)]
        )
        XCTAssertEqual(keyboard.activeDeck, .a)
    }

    func testWholeSurfaceUsesFirstTouchAndIgnoresHorizontalMovement() {
        var machine = GestureStateMachine()
        let first = TouchID(rawValue: 1)
        let second = TouchID(rawValue: 2)

        XCTAssertEqual(
            machine.process(.began([
                point(second, x: 0.9, y: 0.1, time: 0),
                point(first, x: 0.1, y: 0.9, time: 0),
            ], deck: .b, mode: .scratch)),
            [.setScratch(.b, 0)]
        )
        XCTAssertEqual(
            machine.process(.moved([point(first, x: 0.8, y: 0.9, time: 0.01)])),
            []
        )
        XCTAssertEqual(
            machine.process(.moved([point(second, x: 0.9, y: 0.3, time: 0.02)])),
            []
        )
        assertSingleValue(
            machine.process(.moved([point(first, x: 0.8, y: 0.92, time: 0.02)])),
            expected: .scratch(deck: .b, value: 6.6)
        )
    }

    func testScratchDeckAndModeStayFixedUntilTouchEnds() {
        var machine = GestureStateMachine()
        let id = TouchID(rawValue: 1)

        XCTAssertEqual(
            machine.process(.began([
                point(id, x: 0.2, y: 0.2, time: 1),
                point(TouchID(rawValue: 2), x: 0.6, y: 0.2, time: 1)
            ], deck: .a, mode: .scratch)),
            [.setScratch(.a, 0)]
        )
        assertSingleValue(
            machine.process(.moved([point(id, x: 0.95, y: 0.3, time: 1.01)])),
            expected: .scratch(deck: .a, value: 8)
        )
        XCTAssertEqual(machine.process(.began([
            point(TouchID(rawValue: 3), x: 0.7, y: 0.3, time: 1.02)
        ], deck: .b, mode: .pitchBend)), [])
        assertSingleValue(
            machine.process(.moved([point(id, x: 0.95, y: 0.4, time: 1.03)])),
            expected: .scratch(deck: .a, value: 8)
        )
        XCTAssertEqual(machine.process(.ended([id])), [.endScratch(.a)])
    }

    func testPitchBendClampsAndZerosAfterFiftyMilliseconds() {
        var machine = GestureStateMachine()
        let id = TouchID(rawValue: 1)

        XCTAssertEqual(
            machine.process(.began([
                point(id, x: 0.5, y: 0.5, time: 2),
                point(TouchID(rawValue: 2), x: 0.6, y: 0.5, time: 2)
            ], deck: .b, mode: .pitchBend)),
            [.setPitchBend(.b, 0)]
        )
        assertSingleValue(
            machine.process(.moved([point(id, x: 0.2, y: 0.7, time: 2.01)])),
            expected: .bend(deck: .b, value: 8)
        )
        XCTAssertEqual(machine.process(.tick(2.059)), [])
        XCTAssertEqual(machine.process(.tick(2.061)), [.setPitchBend(.b, 0)])
        XCTAssertEqual(machine.process(.tick(2.2)), [])
        XCTAssertEqual(machine.process(.ended([id])), [.endPitchBend(.b)])
    }

    func testRemainingFingerDoesNotJogAndNewSecondFingerRearms() {
        var machine = GestureStateMachine()
        let first = TouchID(rawValue: 1)
        let second = TouchID(rawValue: 2)

        _ = machine.process(.began([
            point(first, x: 0.2, y: 0.4, time: 0),
            point(second, x: 0.8, y: 0.4, time: 0),
        ], deck: .a, mode: .scratch))
        XCTAssertEqual(machine.process(.ended([first])), [.endScratch(.a)])
        XCTAssertEqual(
            machine.process(.moved([point(second, x: 0.8, y: 0.8, time: 0.1)])),
            []
        )
        XCTAssertEqual(
            machine.process(.began([
                point(TouchID(rawValue: 3), x: 0.5, y: 0.5, time: 0.2)
            ], deck: .b, mode: .pitchBend)),
            [.setPitchBend(.b, 0)]
        )
    }

    func testCancellationReleasesOnlyControllingJog() {
        var machine = GestureStateMachine()
        let first = TouchID(rawValue: 1)
        let second = TouchID(rawValue: 2)

        _ = machine.process(.began([
            point(first, x: 0.2, y: 0.4, time: 0),
            point(second, x: 0.8, y: 0.4, time: 0),
        ], deck: .a, mode: .pitchBend))
        XCTAssertEqual(machine.process(.cancelled), [.endPitchBend(.a)])
        XCTAssertEqual(machine.session, .empty)
    }

    func testTraceReplayIsDeterministic() {
        let id = TouchID(rawValue: 1)
        let trace: [GestureInputEvent] = [
            .began([point(id, x: 0.25, y: 0.5, time: 3),
                    point(TouchID(rawValue: 2), x: 0.6, y: 0.5, time: 3)], deck: .b, mode: .scratch),
            .moved([point(id, x: 0.25, y: 0.52, time: 3.01)]),
            .tick(3.07),
            .ended([id]),
        ]

        let firstReplay = replay(trace)
        XCTAssertEqual(firstReplay, replay(trace))
        XCTAssertEqual(firstReplay.count, 4)
        XCTAssertEqual(firstReplay[0], .setScratch(.b, 0))
        assertSingleValue([firstReplay[1]], expected: .scratch(deck: .b, value: 6.6))
        XCTAssertEqual(firstReplay[2], .setScratch(.b, 0))
        XCTAssertEqual(firstReplay[3], .endScratch(.b))
    }

    func testSingleFingerWaitsAndReleasingSecondFingerEndsJog() {
        var machine = GestureStateMachine()
        let first = TouchID(rawValue: 1)
        let second = TouchID(rawValue: 2)
        XCTAssertEqual(machine.process(.began([
            point(first, x: 0.2, y: 0.2, time: 0)
        ], deck: .a, mode: .scratch)), [])
        XCTAssertEqual(machine.process(.moved([
            point(first, x: 0.2, y: 0.4, time: 1)
        ])), [])
        XCTAssertEqual(machine.process(.began([
            point(second, x: 0.6, y: 0.4, time: 2)
        ], deck: .b, mode: .scratch)), [.setScratch(.b, 0)])
        assertSingleValue(machine.process(.moved([
            point(first, x: 0.2, y: 0.42, time: 2.01)
        ])), expected: .scratch(deck: .b, value: 6.6))
        XCTAssertEqual(machine.process(.ended([second])), [.endScratch(.b)])
        XCTAssertEqual(machine.process(.tick(3)), [])
    }

    private enum ExpectedJogValue {
        case scratch(deck: DeckID, value: Double)
        case bend(deck: DeckID, value: Double)
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

    private func assertSingleValue(
        _ actions: [DJAction],
        expected: ExpectedJogValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard actions.count == 1 else {
            return XCTFail("Expected one jog action, got \(actions)", file: file, line: line)
        }

        switch (actions[0], expected) {
        case (.setScratch(let actualDeck, let actualValue), .scratch(let deck, let value)),
             (.setPitchBend(let actualDeck, let actualValue), .bend(let deck, let value)):
            XCTAssertEqual(actualDeck, deck, file: file, line: line)
            XCTAssertEqual(actualValue, value, accuracy: 0.000_001, file: file, line: line)
        default:
            XCTFail("Unexpected jog action \(actions[0])", file: file, line: line)
        }
    }
}
