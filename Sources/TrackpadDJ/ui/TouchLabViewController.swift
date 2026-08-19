import AppKit
import UniformTypeIdentifiers

/// Hosts the TouchLabView and wires it to the AudioEngine.
@MainActor
final class TouchLabViewController: NSViewController {

    private var touchLabView: TouchLabView!
    private let audioEngine = AudioEngine()
    private var displayTimer: Timer?
    private var loadStatusByDeck: [DeckID: String] = [:]
    private var operationStatus: String?

    override func loadView() {
        touchLabView = TouchLabView(frame: NSRect(x: 0, y: 0, width: 1_180, height: 720))
        view = touchLabView
        wireCallbacks()
        refreshDisplaySnapshot()
        startDisplayTimer()
    }

    // MARK: - Display Timer (30 fps playhead update)

    private func startDisplayTimer() {
        displayTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(displayTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func displayTimerFired(_ timer: Timer) {
        refreshDisplaySnapshot()
    }

    private func refreshDisplaySnapshot() {
        touchLabView.apply(
            deckA: audioEngine.snapshot(for: .a),
            deckB: audioEngine.snapshot(for: .b),
            mixer: audioEngine.mixerSnapshot()
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(touchLabView)
    }

    func shutdown() {
        displayTimer?.invalidate()
        displayTimer = nil
        touchLabView?.shutdown()
        audioEngine.shutdown()
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        touchLabView.onAction = { [weak self] action in
            self?.handle(action)
        }
        audioEngine.onRoutingError = { [weak self] _ in
            self?.refreshDisplaySnapshot()
        }
    }

    private func handle(_ action: DJAction) {
        switch action {
        case .selectActiveDeck:
            break
        case .stepCrossfader(let direction):
            audioEngine.stepCrossfader(toward: direction)
        case .load(let deck):
            presentOpenPanel(for: deck)
        case .togglePlay(let deck):
            audioEngine.togglePlayPause(deck: deck)
        case .cue(let deck):
            audioEngine.cue(deck: deck)
        case .nudge(let deck, let delta):
            audioEngine.scrub(deck: deck, deltaX: delta)
        case .adjustFilter(let deck, let delta):
            audioEngine.setFilter(deck: deck, deltaY: delta)
        case .adjustVolume(let deck, let delta):
            audioEngine.setFader(deck: deck, deltaY: delta)
        case .adjustTempo(let deck, let delta):
            audioEngine.adjustTempo(deck: deck, by: delta)
        case .resetTempo(let deck):
            audioEngine.resetTempo(deck: deck)
        case .toggleMonitor(let deck):
            audioEngine.toggleMonitor(deck: deck)
            refreshDisplaySnapshot()
        case .toggleOutputMode:
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.audioEngine.toggleOutputMode()
                    self.refreshDisplaySnapshot()
                } catch {
                    self.refreshDisplaySnapshot()
                }
            }
        case .setScratch(let deck, let rate):
            audioEngine.setScratch(deck: deck, rate: rate)
        case .endScratch(let deck):
            audioEngine.endScratch(deck: deck)
        case .setPitchBend(let deck, let percent):
            audioEngine.setPitchBend(deck: deck, percent: percent)
        case .endPitchBend(let deck):
            audioEngine.endPitchBend(deck: deck)
        case .tapBPM(let deck):
            audioEngine.tapBPM(deck: deck, at: CACurrentMediaTime())
            refreshDisplaySnapshot()
        case .restoreAutomaticBPM(let deck):
            audioEngine.restoreAutomaticBPM(deck: deck)
            operationStatus = "Deck \(deck.displayName) automatic BPM restored"
            refreshStatusMessage()
            refreshDisplaySnapshot()
        case .syncTempo(let deck):
            operationStatus = audioEngine.syncTempo(activeDeck: deck).statusMessage
            refreshStatusMessage()
            refreshDisplaySnapshot()
        case .toggleCursorLock, .cancelJogAndUnlock:
            break
        }
    }

    // MARK: - File Loading

    private func presentOpenPanel(for deckID: DeckID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            self.setLoadStatus(
                "Loading Deck \(deckID == .a ? "A" : "B")…",
                for: deckID
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.audioEngine.loadTrack(url: url, deck: deckID)
                    guard result == .installed else { return }
                    self.touchLabView.resetTransientState(for: deckID)
                    self.refreshDisplaySnapshot()
                    self.setLoadStatus(nil, for: deckID)
                } catch {
                    self.setLoadStatus(
                        "Deck \(deckID == .a ? "A" : "B") failed: \(error.localizedDescription)",
                        for: deckID
                    )
                }
            }
        }
    }

    private func setLoadStatus(_ status: String?, for deck: DeckID) {
        loadStatusByDeck[deck] = status
        refreshStatusMessage()
    }

    private func refreshStatusMessage() {
        let status = [DeckID.a, .b]
            .compactMap { loadStatusByDeck[$0] }
            + [operationStatus].compactMap { $0 }
        let message = status.joined(separator: "   |   ")
        touchLabView.statusMessage = message.isEmpty ? nil : message
    }
}
