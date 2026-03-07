import AppKit
import UniformTypeIdentifiers

/// Hosts the TouchLabView and wires it to the AudioEngine.
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
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.refreshPlayheads()
        }
    }

    private func refreshPlayheads() {
        touchLabView.progressA = audioEngine.deckA.playbackProgress
        touchLabView.progressB = audioEngine.deckB.playbackProgress
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(touchLabView)
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        touchLabView.onCrossfaderChanged = { [weak self] state in
            self?.audioEngine.applyCrossfader(state)
        }

        touchLabView.onLoadDeck = { [weak self] deckID in
            self?.presentOpenPanel(for: deckID)
        }

        touchLabView.onTogglePlay = { [weak self] deckID in
            self?.audioEngine.togglePlayPause(deck: deckID)
            self?.refreshDeckLabels()
        }

        touchLabView.onCue = { [weak self] deckID in
            self?.audioEngine.cue(deck: deckID)
            self?.refreshDeckLabels()
        }

        touchLabView.onNudge = { [weak self] deckID, deltaX in
            self?.audioEngine.scrub(deck: deckID, deltaX: deltaX)
        }

        touchLabView.onNudgeEnd = { _ in }  // no-op: seek-based scrub needs no reset

        touchLabView.onFilter = { [weak self] deckID, deltaY in
            self?.audioEngine.setFilter(deck: deckID, deltaY: deltaY)
        }
    }

    // MARK: - File Loading

    private func presentOpenPanel(for deckID: AudioEngine.DeckID) {
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

    private func refreshWaveform(deck: AudioEngine.DeckID) {
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
