import AVFoundation

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
    private let startsAudioEngine: Bool
    private var splitCueMatrices: [DeckID: SplitCueMatrix] = [:]
    private var isPreparingSplitCue = false

    private(set) var outputMode: OutputMode = .stereoMaster
    private(set) var routingErrorMessage: String?
    var onRoutingError: ((String?) -> Void)?

    private var monitorAEnabled = false
    private var monitorBEnabled = false

    // Current lowpass cutoff per deck [200, 20_000] Hz.
    private var cutoffA: Float = 20_000
    private var cutoffB: Float = 20_000

    // Deck channel faders [0, 1]. Combined with crossfader for master volume.
    private(set) var faderA: Float = 1.0
    private(set) var faderB: Float = 1.0
    private(set) var crossfaderValue: Float = 0.5

    init(
        trackLoader: any TrackLoading = TrackLoader(),
        startsAudioEngine: Bool = true
    ) {
        trackLoadCoordinator = TrackLoadCoordinator(loader: trackLoader)
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

    /// Equal-power crossfade: value 0 = full A, 1 = full B.
    func applyCrossfader(_ state: CrossfaderState) {
        crossfaderValue = state.value
        applyVolumes()
    }

    func adjustCrossfader(by delta: Float) {
        applyCrossfader(CrossfaderState(value: crossfaderValue).nudged(by: delta))
    }

    func stepCrossfader(toward direction: Int) {
        applyCrossfader(CrossfaderState(value: crossfaderValue).stepped(toward: direction))
    }

    func setFader(deck: DeckID, deltaY: Float) {
        switch deck {
        case .a: faderA = max(0, min(1, faderA + deltaY))
        case .b: faderB = max(0, min(1, faderB + deltaY))
        }
        applyVolumes()
    }

    private func applyVolumes() {
        let (aGain, bGain) = CrossfaderCurve.equalPowerGains(at: crossfaderValue)
        _deckA.volume = faderA * aGain
        _deckB.volume = faderB * bGain
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

    func setFilter(deck: DeckID, deltaY: Float) {
        let target = deck == .a ? _deckA : _deckB
        var cutoff = deck == .a ? cutoffA : cutoffB
        cutoff *= pow(10, deltaY * 2.0)
        cutoff = max(200, min(20_000, cutoff))

        if deck == .a { cutoffA = cutoff } else { cutoffB = cutoff }
        target.eqNode.bands[0].frequency = cutoff
    }
}
