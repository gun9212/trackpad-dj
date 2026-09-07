import AVFoundation

enum SyncFailure: Equatable, Sendable {
    case activeDeckBPMMissing
    case referenceDeckBPMMissing
    case requiredTempoOutOfRange(Double)
}

enum SyncResult: Equatable, Sendable {
    case matched(tempoPercent: Double, targetBPM: Double)
    case failed(SyncFailure)

    var statusMessage: String {
        switch self {
        case .matched(let tempoPercent, let targetBPM):
            return String(format: "SYNC %.1f BPM · TEMPO %+.2f%%", targetBPM, tempoPercent)
        case .failed(.activeDeckBPMMissing):
            return "SYNC FAILED · ACTIVE DECK BPM UNAVAILABLE"
        case .failed(.referenceDeckBPMMissing):
            return "SYNC FAILED · OTHER DECK BPM UNAVAILABLE"
        case .failed(.requiredTempoOutOfRange(let value)):
            return String(format: "SYNC FAILED · REQUIRED TEMPO %+.2f%%", value)
        }
    }
}

/// Main-actor owner of the two deck graphs and their output routing.
@MainActor
final class AudioEngine {

    enum TrackLoadResult: Equatable {
        case installed
        case superseded
    }

    var deckA: any DeckProtocol { _deckA }
    var deckB: any DeckProtocol { _deckB }

    private let _deckA = Deck()
    private let _deckB = Deck()
    private var decks: [Deck] { [_deckA, _deckB] }

    private let engine = AVAudioEngine()
    private let trackLoadCoordinator: TrackLoadCoordinator
    private let hotCueLibrary: HotCueLibrary
    private let startsAudioEngine: Bool
    private var splitCueMatrices: [DeckID: SplitCueMatrix] = [:]
    private var isPreparingSplitCue = false
    private var isShutdown = false

    private(set) var outputMode: OutputMode = .stereoMaster
    private(set) var routingErrorMessage: String?
    var onRoutingError: ((String?) -> Void)?

    private var monitorAEnabled = false
    private var monitorBEnabled = false

    // Current lowpass cutoff per deck [200, 20_000] Hz.
    private var cutoffA: Float = 20_000
    private var cutoffB: Float = 20_000
    private var bpmTapA = BPMTapState()
    private var bpmTapB = BPMTapState()

    // Deck channel faders [0, 1]. The crossfader only gates each master path on or off.
    private(set) var faderA: Float = 1.0
    private(set) var faderB: Float = 1.0
    private var crossfaderState = CrossfaderState.center
    var crossfaderValue: Float { crossfaderState.value }

    init(
        trackLoader: any TrackLoading = TrackLoader(),
        startsAudioEngine: Bool = true,
        hotCueStore: HotCueStore = HotCueStore()
    ) {
        let library = HotCueLibrary(store: hotCueStore)
        hotCueLibrary = library
        trackLoadCoordinator = TrackLoadCoordinator(loader: trackLoader, hotCueLibrary: library)
        self.startsAudioEngine = startsAudioEngine
        setup()
    }

    // MARK: - Setup and Routing

    private func setup() {
        for deck in decks {
            engine.attach(deck.eqNode)
            engine.attach(deck.mixerNode)
            engine.attach(deck.cueMixerNode)
        }
        applyVolumes()
        applyMonitorGains(for: outputMode)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(engineConfigurationDidChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )

        do {
            try rebuildOutputGraph(for: outputMode, startEngine: startsAudioEngine)
            publishRoutingError(nil)
        } catch {
            recordRoutingFailure(error)
        }
    }

    @objc nonisolated private func engineConfigurationDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.recoverAfterConfigurationChange()
        }
    }

    private func recoverAfterConfigurationChange() {
        guard !isShutdown else { return }
        do {
            try rebuildOutputGraph(for: outputMode, startEngine: startsAudioEngine)
            publishRoutingError(nil)
        } catch {
            recordRoutingFailure(error)
        }
    }

    private func rebuildOutputGraph(
        for mode: OutputMode,
        startEngine: Bool
    ) throws {
        engine.stop()
        disconnectOutputGraph()

        let mainMixer = engine.mainMixerNode
        if mode == .splitCue {
            let outputFormat = engine.outputNode.outputFormat(forBus: 0)
            guard outputFormat.channelCount >= 2 else {
                throw OutputRoutingError.splitCueRequiresStereoOutput
            }
            guard splitCueMatrices.count == 2 else {
                throw OutputRoutingError.matrixUnavailable
            }
        }

        for (deckID, deck) in [(DeckID.a, _deckA), (.b, _deckB)] {
            let routeFormat = try routeFormat(for: deck)
            switch mode {
            case .stereoMaster:
                engine.connect(deck.eqNode, to: deck.mixerNode, format: routeFormat)
                engine.connect(deck.mixerNode, to: mainMixer, format: nil)
            case .splitCue:
                guard let splitCueMatrix = splitCueMatrices[deckID] else {
                    throw OutputRoutingError.matrixUnavailable
                }
                OutputGraphConnector.split(
                    source: deck.eqNode,
                    masterPath: deck.mixerNode,
                    cuePath: deck.cueMixerNode,
                    format: routeFormat,
                    in: engine
                )
                try OutputGraphConnector.connectMonoPath(
                    deck.mixerNode,
                    to: splitCueMatrix,
                    inputBus: 0,
                    sampleRate: routeFormat.sampleRate,
                    in: engine
                )
                try OutputGraphConnector.connectMonoPath(
                    deck.cueMixerNode,
                    to: splitCueMatrix,
                    inputBus: 1,
                    sampleRate: routeFormat.sampleRate,
                    in: engine
                )
                try OutputGraphConnector.connectMatrixOutput(
                    splitCueMatrix,
                    to: mainMixer,
                    sampleRate: routeFormat.sampleRate,
                    in: engine
                )
            }
        }

        applyVolumes()
        applyMonitorGains(for: mode)
        engine.prepare()
        if startEngine {
            try engine.start()
        }
    }

    private func routeFormat(for deck: Deck) throws -> AVAudioFormat {
        if let format = deck.processingFormat {
            return format
        }

        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0 else {
            throw OutputRoutingError.invalidRouteFormat
        }
        let channels = max(1, min(output.channelCount, 2))
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: output.sampleRate,
            channels: channels
        ) else {
            throw OutputRoutingError.invalidRouteFormat
        }
        return format
    }

    private func disconnectOutputGraph() {
        for deck in decks {
            engine.disconnectNodeOutput(deck.eqNode)
            engine.disconnectNodeInput(deck.mixerNode)
            engine.disconnectNodeOutput(deck.mixerNode)
            engine.disconnectNodeInput(deck.cueMixerNode)
            engine.disconnectNodeOutput(deck.cueMixerNode)
        }
        for splitCueMatrix in splitCueMatrices.values {
            engine.disconnectNodeInput(splitCueMatrix.node)
            engine.disconnectNodeOutput(splitCueMatrix.node)
        }
    }

    /// Tears down every connection explicitly so AVFAudio never has to infer
    /// the destruction order of a one-to-many Split Cue graph.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        NotificationCenter.default.removeObserver(
            self,
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        engine.stop()
        disconnectOutputGraph()

        for deck in decks {
            if let source = deck.sourceNode {
                engine.disconnectNodeOutput(source)
                engine.detach(source)
            }
            engine.disconnectNodeInput(deck.eqNode)
            engine.detach(deck.eqNode)
            engine.detach(deck.mixerNode)
            engine.detach(deck.cueMixerNode)
        }
        for splitCueMatrix in splitCueMatrices.values {
            engine.detach(splitCueMatrix.node)
        }
        splitCueMatrices.removeAll()
    }

    private func recordRoutingFailure(_ error: Error) {
        engine.stop()
        _deckA.cueVolume = 0
        _deckB.cueVolume = 0
        publishRoutingError(error.localizedDescription)
    }

    private func publishRoutingError(_ message: String?) {
        routingErrorMessage = message
        onRoutingError?(message)
    }

    func setOutputMode(_ mode: OutputMode) async throws {
        guard mode != outputMode else { return }
        do {
            if mode == .splitCue, splitCueMatrices.count != 2 {
                // Ignore a second mode key press while the shared routing nodes are loading.
                guard !isPreparingSplitCue else { return }
                isPreparingSplitCue = true
                do {
                    let deckAMatrix = try await SplitCueMatrix.instantiate()
                    let deckBMatrix = try await SplitCueMatrix.instantiate()
                    engine.stop()
                    engine.attach(deckAMatrix.node)
                    engine.attach(deckBMatrix.node)
                    splitCueMatrices = [.a: deckAMatrix, .b: deckBMatrix]
                    isPreparingSplitCue = false
                } catch {
                    isPreparingSplitCue = false
                    throw error
                }
            }
            try rebuildOutputGraph(for: mode, startEngine: startsAudioEngine)
            outputMode = mode
            publishRoutingError(nil)
        } catch {
            recordRoutingFailure(error)
            throw error
        }
    }

    func toggleOutputMode() async throws {
        try await setOutputMode(outputMode == .stereoMaster ? .splitCue : .stereoMaster)
    }

    // MARK: - Monitoring

    func toggleMonitor(deck: DeckID) {
        switch deck {
        case .a: monitorAEnabled.toggle()
        case .b: monitorBEnabled.toggle()
        }
        applyMonitorGains(for: outputMode)
    }

    func isMonitorEnabled(deck: DeckID) -> Bool {
        deck == .a ? monitorAEnabled : monitorBEnabled
    }

    func monitorGain(deck: DeckID) -> Float {
        deck == .a ? _deckA.cueVolume : _deckB.cueVolume
    }

    private func applyMonitorGains(for mode: OutputMode) {
        guard mode == .splitCue else {
            _deckA.cueVolume = 0
            _deckB.cueVolume = 0
            return
        }
        let gains = CueMonitorGains.values(
            deckAEnabled: monitorAEnabled,
            deckBEnabled: monitorBEnabled
        )
        _deckA.cueVolume = gains.deckA
        _deckB.cueVolume = gains.deckB
    }

    // MARK: - Crossfader and Channel Faders

    /// Three-position output gate: A only, both decks, or B only.
    func applyCrossfader(_ state: CrossfaderState) {
        crossfaderState = state
        applyVolumes()
    }

    func stepCrossfader(toward direction: Int) {
        applyCrossfader(crossfaderState.stepped(toward: direction))
    }

    func setFader(deck: DeckID, deltaY: Float) {
        switch deck {
        case .a: faderA = max(0, min(1, faderA + deltaY))
        case .b: faderB = max(0, min(1, faderB + deltaY))
        }
        applyVolumes()
    }

    private func applyVolumes() {
        let (aGain, bGain) = CrossfaderGate.gains(for: crossfaderState)
        _deckA.volume = faderA * aGain
        _deckB.volume = faderB * bGain
    }

    // MARK: - UI Snapshots

    func snapshot(for deckID: DeckID) -> DeckSnapshot {
        let deck = deckID == .a ? _deckA : _deckB
        let cutoff = deckID == .a ? cutoffA : cutoffB
        let beatGrid = deck.beatGrid
        return DeckSnapshot(
            deck: deckID,
            trackName: deck.trackName,
            isPlaying: deck.isPlaying,
            playbackProgress: deck.playbackProgress,
            extendedProgress: deck.extendedProgress,
            duration: deck.duration,
            tempoPercent: deck.tempoPercent,
            pitchBendPercent: deck.pitchBendPercent,
            bpm: beatGrid?.bpm,
            firstBeatTime: beatGrid?.firstBeatTime,
            beatGridSource: beatGrid?.source,
            beatConfidence: beatGrid?.confidence,
            waveformSamples: deck.waveformSamples,
            preFaderPeak: deck.consumePreFaderPeak(),
            faderLevel: deckID == .a ? faderA : faderB,
            filterLevel: normalizedFilterLevel(for: cutoff),
            monitorEnabled: isMonitorEnabled(deck: deckID),
            hotCues: deck.hotCues,
            hotCueStorageMessage: deck.trackID.map { hotCueLibrary.status(for: $0) }
                ?? (deck.trackName == nil ? nil : "HOT CUES · SESSION ONLY")
        )
    }

    func mixerSnapshot() -> MixerSnapshot {
        MixerSnapshot(
            crossfaderValue: crossfaderValue,
            outputMode: outputMode,
            routingErrorMessage: routingErrorMessage
        )
    }

    private func normalizedFilterLevel(for cutoff: Float) -> Float {
        min(1, max(0, log10(cutoff / 200) / 2))
    }

    // MARK: - Tempo

    func adjustTempo(deck: DeckID, by delta: Double) {
        let target = deck == .a ? _deckA : _deckB
        target.adjustTempoPercent(by: delta)
    }

    func resetTempo(deck: DeckID) {
        let target = deck == .a ? _deckA : _deckB
        target.resetTempo()
    }

    func syncTempo(activeDeck: DeckID) -> SyncResult {
        let active = deck(for: activeDeck)
        let reference = deck(for: activeDeck.other)
        guard let activeBPM = active.beatGrid?.bpm else {
            return .failed(.activeDeckBPMMissing)
        }
        guard let referenceBPM = reference.beatGrid?.bpm else {
            return .failed(.referenceDeckBPMMissing)
        }

        let targetBPM = referenceBPM * (1 + reference.tempoPercent / 100)
        let requiredTempo = (targetBPM / activeBPM - 1) * 100
        guard requiredTempo.isFinite, (-8.0...8.0).contains(requiredTempo) else {
            return .failed(.requiredTempoOutOfRange(requiredTempo))
        }

        active.setTempoPercent(requiredTempo)
        return .matched(tempoPercent: requiredTempo, targetBPM: targetBPM)
    }

    // MARK: - BPM

    func tapBPM(deck deckID: DeckID, at timestamp: TimeInterval) {
        let target = deck(for: deckID)
        guard target.duration > 0 else { return }

        let playbackTime = target.extendedProgress * target.duration
        switch deckID {
        case .a:
            bpmTapA.tap(at: timestamp, progress: playbackTime)
            applyTapGrid(bpmTapA, to: target)
        case .b:
            bpmTapB.tap(at: timestamp, progress: playbackTime)
            applyTapGrid(bpmTapB, to: target)
        }
    }

    func restoreAutomaticBPM(deck deckID: DeckID) {
        switch deckID {
        case .a: bpmTapA.reset()
        case .b: bpmTapB.reset()
        }
        deck(for: deckID).restoreAutomaticBeatGrid()
    }

    private func applyTapGrid(_ tap: BPMTapState, to deck: Deck) {
        guard tap.tapTimes.count >= 2, tap.bpm > 0 else { return }
        deck.applyBeatGrid(BeatGrid(
            bpm: tap.bpm,
            firstBeatTime: tap.beatOffset,
            confidence: 1,
            source: .tap
        ))
    }

    // MARK: - Track Loading

    func loadTrack(url: URL, deck: DeckID) async throws -> TrackLoadResult {
        switch try await trackLoadCoordinator.load(url: url, deck: deck) {
        case .superseded:
            return .superseded
        case .ready(let track):
            let target = deck == .a ? _deckA : _deckB
            let oldSource = target.sourceNode

            engine.stop()
            disconnectOutputGraph()
            if let oldSource {
                engine.detach(oldSource)
            }
            target.install(track)
            if let id = track.trackID { target.applyHotCues(hotCueLibrary.cues(for: id)) }
            switch deck {
            case .a: bpmTapA.reset()
            case .b: bpmTapB.reset()
            }

            guard let source = target.sourceNode,
                  let format = target.processingFormat else {
                return .installed
            }
            engine.attach(source)
            engine.connect(source, to: target.eqNode, format: format)

            do {
                try rebuildOutputGraph(for: outputMode, startEngine: startsAudioEngine)
                publishRoutingError(nil)
                return .installed
            } catch {
                recordRoutingFailure(error)
                throw error
            }
        }
    }

    // MARK: - Transport and Realtime Controls

    func activateHotCue(deck: DeckID, slot: HotCueSlot) {
        let target = deck == .a ? _deckA : _deckB
        if target.activateHotCue(slot) { publishHotCues(from: target) }
    }

    func clearHotCue(deck: DeckID, slot: HotCueSlot) {
        let target = deck == .a ? _deckA : _deckB
        if target.clearHotCue(slot) { publishHotCues(from: target) }
    }

    private func publishHotCues(from source: Deck) {
        guard let id = source.trackID else { return }
        hotCueLibrary.update(source.hotCues, for: id)
        for deck in decks where deck !== source && deck.trackID == id {
            deck.applyHotCues(source.hotCues)
        }
    }

    func flushHotCues() async -> Bool { await hotCueLibrary.flush() }

    func togglePlayPause(deck: DeckID) {
        (deck == .a ? _deckA : _deckB).togglePlayPause()
    }

    func cue(deck: DeckID) {
        (deck == .a ? _deckA : _deckB).cue()
    }

    func scrub(deck: DeckID, deltaX: Float) {
        (deck == .a ? _deckA : _deckB).scrub(normalizedDelta: Double(deltaX))
    }

    func setScratch(deck: DeckID, rate: Double) {
        (deck == .a ? _deckA : _deckB).setScratch(rate: rate)
    }

    func endScratch(deck: DeckID) {
        (deck == .a ? _deckA : _deckB).endScratch()
    }

    func setPitchBend(deck: DeckID, percent: Double) {
        (deck == .a ? _deckA : _deckB).setPitchBendPercent(percent)
    }

    func endPitchBend(deck: DeckID) {
        (deck == .a ? _deckA : _deckB).endPitchBend()
    }

    func setFilter(deck: DeckID, deltaY: Float) {
        let target = deck == .a ? _deckA : _deckB
        var cutoff = deck == .a ? cutoffA : cutoffB
        cutoff *= pow(10, deltaY * 2.0)
        cutoff = max(200, min(20_000, cutoff))

        if deck == .a { cutoffA = cutoff } else { cutoffB = cutoff }
        target.eqNode.bands[0].frequency = cutoff
    }

    private func deck(for deckID: DeckID) -> Deck {
        deckID == .a ? _deckA : _deckB
    }
}
