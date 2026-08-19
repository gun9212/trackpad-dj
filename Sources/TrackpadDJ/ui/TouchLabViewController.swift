import AppKit
import UniformTypeIdentifiers

/// Hosts the TouchLabView and wires it to the AudioEngine.
@MainActor
final class TouchLabViewController: NSViewController {

    private var touchLabView: TouchLabView!
    private let audioEngine = AudioEngine()
    private var displayTimer: Timer?

    override func loadView() {
        touchLabView = TouchLabView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view = touchLabView
        wireCallbacks()
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
        refreshPlayheads()
    }

    private func refreshPlayheads() {
        touchLabView.progressA = audioEngine.deckA.playbackProgress
        touchLabView.progressB = audioEngine.deckB.playbackProgress
        touchLabView.extendedProgressA = audioEngine.deckA.extendedProgress
        touchLabView.extendedProgressB = audioEngine.deckB.extendedProgress
        touchLabView.durationA  = audioEngine.deckA.duration
        touchLabView.durationB  = audioEngine.deckB.duration
        touchLabView.faderA = audioEngine.faderA
        touchLabView.faderB = audioEngine.faderB
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(touchLabView)
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        touchLabView.onAction = { [weak self] action in
            self?.handle(action)
        }
    }

    private func handle(_ action: DJAction) {
        switch action {
        case .adjustCrossfader(let delta):
            audioEngine.adjustCrossfader(by: delta)
        case .stepCrossfader(let direction):
            audioEngine.stepCrossfader(toward: direction)
        case .load(let deck):
            presentOpenPanel(for: deck)
        case .togglePlay(let deck):
            audioEngine.togglePlayPause(deck: deck)
            refreshDeckLabels()
        case .cue(let deck):
            audioEngine.cue(deck: deck)
            refreshDeckLabels()
        case .nudge(let deck, let delta):
            audioEngine.scrub(deck: deck, deltaX: delta)
        case .adjustFilter(let deck, let delta):
            audioEngine.setFilter(deck: deck, deltaY: delta)
        case .adjustVolume(let deck, let delta):
            audioEngine.setFader(deck: deck, deltaY: delta)
        case .setScratch(let deck, let rate):
            audioEngine.setScratch(deck: deck, rate: rate)
        case .endScratch(let deck):
            audioEngine.endScratch(deck: deck)
        case .tapBPM, .setHotCue, .jumpToHotCue:
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
            do {
                try self.audioEngine.loadTrack(url: url, deck: deckID)
                DispatchQueue.main.async {
                    self.refreshDeckLabels()
                    self.refreshWaveform(deck: deckID)
                }
            } catch {
                print("Load error: \(error)")
            }
        }
    }

    // MARK: - HUD Updates

    private func refreshWaveform(deck: DeckID) {
        switch deck {
        case .a: touchLabView.waveformA = audioEngine.deckA.waveformSamples
        case .b: touchLabView.waveformB = audioEngine.deckB.waveformSamples
        }
    }

    private func refreshDeckLabels() {
        let a = audioEngine.deckA
        let b = audioEngine.deckB
        touchLabView.deckALabel = "A: \(a.trackName ?? "—")  \(a.isPlaying ? "▶" : "■")"
        touchLabView.deckBLabel = "\(b.isPlaying ? "▶" : "■")  \(b.trackName ?? "—") :B"
    }
}
