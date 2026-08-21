import AppKit
import XCTest
@testable import TrackpadDJ

final class PerformanceUITests: XCTestCase {

    func testResponsiveLayoutsKeepControlsInsideBoundsWithoutOverlap() {
        let sizes = [
            NSSize(width: 960, height: 620),
            NSSize(width: 1_180, height: 720),
            NSSize(width: 1_600, height: 900),
        ]

        for size in sizes {
            let bounds = NSRect(origin: .zero, size: size)
            let layout = PerformanceLayout(bounds: bounds)
            XCTAssertEqual(layout.controlRegions.count, 13)

            for region in layout.controlRegions {
                XCTAssertGreaterThan(region.frame.width, 0)
                XCTAssertGreaterThan(region.frame.height, 0)
                XCTAssertGreaterThanOrEqual(region.frame.minX, bounds.minX)
                XCTAssertGreaterThanOrEqual(region.frame.minY, bounds.minY)
                XCTAssertLessThanOrEqual(region.frame.maxX, bounds.maxX)
                XCTAssertLessThanOrEqual(region.frame.maxY, bounds.maxY)
            }

            for firstIndex in layout.controlRegions.indices {
                for secondIndex in layout.controlRegions.indices where secondIndex > firstIndex {
                    let first = layout.controlRegions[firstIndex]
                    let second = layout.controlRegions[secondIndex]
                    XCTAssertFalse(
                        first.frame.intersects(second.frame),
                        "\(first.control) overlaps \(second.control) at \(size)"
                    )
                }
            }
        }
    }

    func testLayoutStacksWaveformsAndKeepsSinglePlatterInCenterConsole() {
        let compact = PerformanceLayout(bounds: NSRect(x: 0, y: 0, width: 960, height: 620))
        let regular = PerformanceLayout(bounds: NSRect(x: 0, y: 0, width: 1_180, height: 720))

        XCTAssertTrue(compact.isCompact)
        XCTAssertFalse(regular.isCompact)
        XCTAssertGreaterThan(regular.deckAWaveform.minY, regular.deckBWaveform.minY)
        XCTAssertLessThan(regular.console.maxY, regular.waveformStage.minY)
        XCTAssertGreaterThan(regular.centerConsole.minX, regular.deckAConsole.maxX)
        XCTAssertLessThan(regular.centerConsole.maxX, regular.deckBConsole.minX)
        XCTAssertTrue(regular.centerConsole.contains(NSPoint(
            x: regular.platter.midX,
            y: regular.platter.midY
        )))
        XCTAssertEqual(regular.platter.width, regular.platter.height)
    }

    func testControlHitTestingUsesDrawnRegions() {
        let layout = PerformanceLayout(bounds: NSRect(x: 0, y: 0, width: 1_180, height: 720))

        for region in layout.controlRegions {
            XCTAssertEqual(
                layout.control(at: NSPoint(x: region.frame.midX, y: region.frame.midY)),
                region.control
            )
        }
        XCTAssertNil(layout.control(at: NSPoint(x: layout.platter.midX, y: layout.platter.midY)))
    }

    func testControlPolicyDisablesTransportAndSyncUntilTracksAreReady() {
        let emptyA = DeckSnapshot.empty(deck: .a)
        let emptyB = DeckSnapshot.empty(deck: .b)
        XCTAssertTrue(PerformanceControlPolicy.isEnabled(.load(.a), deckA: emptyA, deckB: emptyB))
        XCTAssertTrue(PerformanceControlPolicy.isEnabled(.monitor(.b), deckA: emptyA, deckB: emptyB))
        XCTAssertTrue(PerformanceControlPolicy.isEnabled(.toggleOutputMode, deckA: emptyA, deckB: emptyB))
        XCTAssertFalse(PerformanceControlPolicy.isEnabled(.togglePlay(.a), deckA: emptyA, deckB: emptyB))
        XCTAssertFalse(PerformanceControlPolicy.isEnabled(.cue(.b), deckA: emptyA, deckB: emptyB))
        XCTAssertFalse(PerformanceControlPolicy.isEnabled(.sync(.a), deckA: emptyA, deckB: emptyB))

        let readyA = snapshot(deck: .a, bpm: 120)
        let readyB = snapshot(deck: .b, bpm: 124)
        XCTAssertTrue(PerformanceControlPolicy.isEnabled(.togglePlay(.a), deckA: readyA, deckB: readyB))
        XCTAssertTrue(PerformanceControlPolicy.isEnabled(.cue(.b), deckA: readyA, deckB: readyB))
        XCTAssertTrue(PerformanceControlPolicy.isEnabled(.sync(.a), deckA: readyA, deckB: readyB))
    }

    func testFirstUnlockedTouchOverControlReservesWholeSequenceForClick() {
        XCTAssertTrue(TouchRoutingPolicy.reservesSequenceForControl(
            sequenceWasEmpty: true,
            cursorLocked: false,
            controlUnderPointer: .togglePlay(.a)
        ))
        XCTAssertFalse(TouchRoutingPolicy.reservesSequenceForControl(
            sequenceWasEmpty: false,
            cursorLocked: false,
            controlUnderPointer: .togglePlay(.a)
        ))
        XCTAssertFalse(TouchRoutingPolicy.reservesSequenceForControl(
            sequenceWasEmpty: true,
            cursorLocked: true,
            controlUnderPointer: .togglePlay(.a)
        ))
        XCTAssertFalse(TouchRoutingPolicy.reservesSequenceForControl(
            sequenceWasEmpty: true,
            cursorLocked: false,
            controlUnderPointer: nil
        ))
    }

    func testInactiveDeckButtonSelectsDeckBeforeExecutingItsCommand() {
        var keyboard = KeyboardStateMachine()

        XCTAssertEqual(
            keyboard.activate(.togglePlay(.b)),
            [.selectActiveDeck(.b), .togglePlay(.b)]
        )
        XCTAssertEqual(keyboard.activeDeck, .b)
        XCTAssertEqual(keyboard.activate(.load(.b)), [.load(.b)])
        XCTAssertEqual(keyboard.activate(.selectDeck(.b)), [])
        XCTAssertEqual(keyboard.activate(.selectDeck(.a)), [.selectActiveDeck(.a)])
        XCTAssertEqual(keyboard.activate(.toggleOutputMode), [.toggleOutputMode])
        XCTAssertEqual(keyboard.activeDeck, .a)
    }

    @MainActor
    func testPerformanceConsoleRendersAtMinimumAndDefaultSizes() {
        for size in [NSSize(width: 960, height: 620), NSSize(width: 1_180, height: 720)] {
            let view = TouchLabView(frame: NSRect(origin: .zero, size: size))
            view.apply(
                deckA: snapshot(deck: .a, bpm: 120),
                deckB: snapshot(deck: .b, bpm: 124),
                mixer: .initial
            )

            let rendered = view.dataWithPDF(inside: view.bounds)
            XCTAssertGreaterThan(rendered.count, 1_000)
            view.shutdown()
        }
    }

    @MainActor
    func testPerformanceConsoleRendererDrawsImmutableSnapshotOffscreen() {
        let size = NSSize(width: 1_180, height: 720)
        let state = PerformanceConsoleRenderState(
            bounds: NSRect(origin: .zero, size: size),
            deckA: snapshot(deck: .a, bpm: 120),
            deckB: snapshot(deck: .b, bpm: 124),
            mixer: .initial,
            activeDeck: .b,
            jogDeck: .a,
            jogMode: .pitchBend,
            jogValue: 2.5,
            touchSession: .empty,
            isCursorLocked: true,
            hoveredControl: nil,
            pressedControl: nil,
            displayedPeakA: 0.8,
            displayedPeakB: 0.5,
            activeDeckTransitionProgress: 0.4,
            reducesMotion: false,
            statusMessage: "TEST STATUS",
            cursorStatusMessage: nil
        )
        let image = NSImage(size: size)

        image.lockFocus()
        PerformanceConsoleRenderer(state: state).draw()
        image.unlockFocus()

        XCTAssertGreaterThan(image.tiffRepresentation?.count ?? 0, 1_000)
    }

    private func snapshot(deck: DeckID, bpm: Double) -> DeckSnapshot {
        DeckSnapshot(
            deck: deck,
            trackName: "Test Track \(deck.displayName)",
            isPlaying: deck == .a,
            playbackProgress: 0.4,
            extendedProgress: 0.4,
            duration: 180,
            tempoPercent: 1.25,
            pitchBendPercent: 0,
            bpm: bpm,
            firstBeatTime: 0.25,
            beatGridSource: .automatic,
            beatConfidence: 0.82,
            waveformSamples: (0..<600).map { Float(($0 % 30) + 1) / 30 },
            preFaderPeak: deck == .a ? 0.8 : 0.5,
            faderLevel: deck == .a ? 0.9 : 0.75,
            filterLevel: 0.85,
            monitorEnabled: deck == .b
        )
    }
}
