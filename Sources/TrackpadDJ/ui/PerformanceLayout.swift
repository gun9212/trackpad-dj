import AppKit

enum PerformanceControl: Equatable, Hashable {
    case selectDeck(DeckID)
    case load(DeckID)
    case cue(DeckID)
    case hotCue(DeckID, HotCueSlot)
    case togglePlay(DeckID)
    case sync(DeckID)
    case monitor(DeckID)
    case toggleOutputMode

    var deck: DeckID? {
        switch self {
        case .hotCue(let deck, _): return deck
        case .selectDeck(let deck), .load(let deck), .cue(let deck),
             .togglePlay(let deck), .sync(let deck), .monitor(let deck):
            return deck
        case .toggleOutputMode:
            return nil
        }
    }

    var action: DJAction? {
        switch self {
        case .hotCue(let deck, let slot): return .activateHotCue(deck, slot)
        case .selectDeck(let deck): return .selectActiveDeck(deck)
        case .load(let deck): return .load(deck)
        case .cue(let deck): return .cue(deck)
        case .togglePlay(let deck): return .togglePlay(deck)
        case .sync(let deck): return .syncTempo(deck)
        case .monitor(let deck): return .toggleMonitor(deck)
        case .toggleOutputMode: return .toggleOutputMode
        }
    }

    var title: String {
        switch self {
        case .hotCue(_, let slot): return "HOT \(slot.rawValue)"
        case .selectDeck(let deck): return "DECK \(deck.displayName)"
        case .load: return "LOAD"
        case .cue: return "CUE"
        case .togglePlay: return "PLAY"
        case .sync: return "SYNC"
        case .monitor: return "MON"
        case .toggleOutputMode: return "OUTPUT"
        }
    }

    var keyHint: String? {
        switch self {
        case .hotCue(_, let slot): return "\(slot.rawValue)"
        case .selectDeck: return "TAB"
        case .load: return "Q"
        case .cue: return "C"
        case .togglePlay: return "SPACE"
        case .sync: return "S"
        case .monitor: return "V"
        case .toggleOutputMode: return "M"
        }
    }
}

struct PerformanceControlRegion: Equatable {
    let control: PerformanceControl
    let frame: NSRect
}

/// Computes drawing and hit-test geometry from one source of truth.
struct PerformanceLayout {
    let bounds: NSRect
    let topBar: NSRect
    let bottomRail: NSRect
    let waveformStage: NSRect
    let deckAWaveform: NSRect
    let deckBWaveform: NSRect
    let console: NSRect
    let deckAConsole: NSRect
    let centerConsole: NSRect
    let deckBConsole: NSRect
    let platter: NSRect
    let crossfader: NSRect
    let controlRegions: [PerformanceControlRegion]
    let isCompact: Bool

    init(bounds: NSRect) {
        self.bounds = bounds
        isCompact = bounds.width < 1_080

        let sideInset: CGFloat = 20
        let topHeight: CGFloat = 54
        let bottomHeight: CGFloat = 34
        topBar = NSRect(
            x: bounds.minX + sideInset,
            y: bounds.maxY - topHeight,
            width: max(0, bounds.width - sideInset * 2),
            height: topHeight
        )
        bottomRail = NSRect(
            x: bounds.minX + sideInset,
            y: bounds.minY,
            width: max(0, bounds.width - sideInset * 2),
            height: bottomHeight
        )

        let workTop = topBar.minY - 8
        let workBottom = bottomRail.maxY + 8
        let workHeight = max(0, workTop - workBottom)
        let waveformHeight = min(310, max(228, workHeight * 0.47))
        waveformStage = NSRect(
            x: bounds.minX + sideInset,
            y: workTop - waveformHeight,
            width: max(0, bounds.width - sideInset * 2),
            height: waveformHeight
        )

        let waveformGap: CGFloat = 6
        let bandHeight = max(0, (waveformStage.height - waveformGap) / 2)
        deckBWaveform = NSRect(
            x: waveformStage.minX,
            y: waveformStage.minY,
            width: waveformStage.width,
            height: bandHeight
        )
        deckAWaveform = NSRect(
            x: waveformStage.minX,
            y: deckBWaveform.maxY + waveformGap,
            width: waveformStage.width,
            height: bandHeight
        )

        console = NSRect(
            x: waveformStage.minX,
            y: workBottom,
            width: waveformStage.width,
            height: max(0, waveformStage.minY - workBottom - 8)
        )

        let columnGap: CGFloat = 12
        let centerWidth = min(420, max(300, console.width * 0.34))
        let sideWidth = max(0, (console.width - centerWidth - columnGap * 2) / 2)
        deckAConsole = NSRect(
            x: console.minX,
            y: console.minY,
            width: sideWidth,
            height: console.height
        )
        centerConsole = NSRect(
            x: deckAConsole.maxX + columnGap,
            y: console.minY,
            width: centerWidth,
            height: console.height
        )
        deckBConsole = NSRect(
            x: centerConsole.maxX + columnGap,
            y: console.minY,
            width: sideWidth,
            height: console.height
        )

        let platterDiameter = max(
            120,
            min(214, centerConsole.width - 54, centerConsole.height - 82)
        )
        platter = NSRect(
            x: centerConsole.midX - platterDiameter / 2,
            y: centerConsole.maxY - platterDiameter - 6,
            width: platterDiameter,
            height: platterDiameter
        )
        crossfader = NSRect(
            x: centerConsole.minX + 26,
            y: centerConsole.minY + 10,
            width: max(0, centerConsole.width - 52),
            height: 42
        )

        var controls: [PerformanceControlRegion] = []
        controls.append(PerformanceControlRegion(
            control: .toggleOutputMode,
            frame: NSRect(
                x: topBar.maxX - 154,
                y: topBar.midY - 16,
                width: 154,
                height: 32
            )
        ))
        controls.append(contentsOf: Self.deckControls(deck: .a, in: deckAConsole, mirrored: false))
        controls.append(contentsOf: Self.deckControls(deck: .b, in: deckBConsole, mirrored: true))
        controlRegions = controls
    }

    func region(for control: PerformanceControl) -> PerformanceControlRegion? {
        controlRegions.first { $0.control == control }
    }

    func control(at point: NSPoint) -> PerformanceControl? {
        controlRegions.last { $0.frame.contains(point) }?.control
    }

    private static func deckControls(
        deck: DeckID,
        in rect: NSRect,
        mirrored: Bool
    ) -> [PerformanceControlRegion] {
        let selector = PerformanceControlRegion(
            control: .selectDeck(deck),
            frame: NSRect(
                x: rect.minX,
                y: rect.maxY - 38,
                width: rect.width,
                height: 38
            )
        )
        var buttons: [PerformanceControl] = [
            .load(deck), .cue(deck), .togglePlay(deck), .sync(deck), .monitor(deck),
        ]
        if mirrored {
            buttons.reverse()
        }

        let inset: CGFloat = 8
        let gap: CGFloat = 6
        let availableWidth = max(0, rect.width - inset * 2 - gap * 4)
        let buttonWidth = availableWidth / 5
        let buttonY = rect.minY + 12
        let buttonHeight: CGFloat = 44
        let regions = buttons.enumerated().map { index, control in
            PerformanceControlRegion(
                control: control,
                frame: NSRect(
                    x: rect.minX + inset + CGFloat(index) * (buttonWidth + gap),
                    y: buttonY,
                    width: buttonWidth,
                    height: buttonHeight
                )
            )
        }
        let padWidth = max(0, rect.width - inset * 2 - gap * 3) / 4
        let pads = HotCueSlot.allCases.map { slot in
            PerformanceControlRegion(control: .hotCue(deck, slot), frame: NSRect(
                x: rect.minX + inset + CGFloat(slot.index) * (padWidth + gap),
                y: buttonY + buttonHeight + 8, width: padWidth, height: 40
            ))
        }
        return [selector] + regions + pads
    }
}

enum PerformanceControlPolicy {
    static func isEnabled(
        _ control: PerformanceControl,
        deckA: DeckSnapshot,
        deckB: DeckSnapshot
    ) -> Bool {
        switch control {
        case .selectDeck, .load, .monitor, .toggleOutputMode:
            return true
        case .cue(let deck), .togglePlay(let deck), .hotCue(let deck, _):
            return snapshot(for: deck, deckA: deckA, deckB: deckB).duration > 0
        case .sync:
            return deckA.bpm != nil && deckB.bpm != nil
        }
    }

    private static func snapshot(
        for deck: DeckID,
        deckA: DeckSnapshot,
        deckB: DeckSnapshot
    ) -> DeckSnapshot {
        deck == .a ? deckA : deckB
    }
}

enum TouchRoutingPolicy {
    static func reservesSequenceForControl(
        sequenceWasEmpty: Bool,
        cursorLocked: Bool,
        controlUnderPointer: PerformanceControl?
    ) -> Bool {
        sequenceWasEmpty && !cursorLocked && controlUnderPointer != nil
    }
}

extension KeyboardStateMachine {
    mutating func activate(_ control: PerformanceControl, shift: Bool = false) -> [DJAction] {
        var actions: [DJAction] = []
        if let deck = control.deck,
           let selection = selectActiveDeck(deck) {
            actions.append(selection)
        }
        if case .selectDeck = control {
            return actions
        }
        if case .hotCue(let deck, let slot) = control, shift {
            actions.append(.clearHotCue(deck, slot))
        } else if let action = control.action {
            actions.append(action)
        }
        return actions
    }
}
