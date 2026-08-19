import Foundation

/// Coherent deck state consumed by the UI during one display refresh.
struct DeckSnapshot: Equatable, Sendable {
    let deck: DeckID
    let trackName: String?
    let isPlaying: Bool
    let playbackProgress: Double
    let extendedProgress: Double
    let duration: Double
    let tempoPercent: Double
    let waveformSamples: [Float]
    let faderLevel: Float
    let filterLevel: Float
    let monitorEnabled: Bool

    static func empty(deck: DeckID) -> DeckSnapshot {
        DeckSnapshot(
            deck: deck,
            trackName: nil,
            isPlaying: false,
            playbackProgress: 0,
            extendedProgress: 0,
            duration: 0,
            tempoPercent: 0,
            waveformSamples: [],
            faderLevel: 1,
            filterLevel: 1,
            monitorEnabled: false
        )
    }
}

/// Shared mixer and output state captured alongside both deck snapshots.
struct MixerSnapshot: Equatable, Sendable {
    let crossfaderValue: Float
    let outputMode: OutputMode
    let routingErrorMessage: String?

    static let initial = MixerSnapshot(
        crossfaderValue: CrossfaderState.center.value,
        outputMode: .stereoMaster,
        routingErrorMessage: nil
    )
}
