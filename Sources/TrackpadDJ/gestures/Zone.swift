import CoreGraphics

/// A named region of the trackpad surface in normalized [0, 1] × [0, 1] space.
struct Zone {

    enum Name: String, CaseIterable {
        case topStrip    = "Browse"
        case deckA       = "Deck A"
        case deckB       = "Deck B"
        case bottomStrip = "Crossfader"
    }

    let name: Name

    /// Rectangle in normalized trackpad space (origin lower-left).
    let rect: CGRect

    func contains(_ position: CGPoint) -> Bool {
        rect.contains(position)
    }
}

/// Default zone layout for the trackpad.
///
/// Layout (Y increases upward):
///
///   ┌─────────────────────┐  y = 1.0
///   │      Browse         │  top strip  (h = 0.20)
///   ├──────────┬──────────┤  y = 0.80
///   │          │          │
///   │  Deck A  │  Deck B  │  deck zones (h = 0.65)
///   │          │          │
///   ├──────────┴──────────┤  y = 0.15
///   │     Crossfader      │  bottom strip (h = 0.15)
///   └─────────────────────┘  y = 0.0
///
enum ZoneLayout {

    static let all: [Zone] = [
        Zone(name: .topStrip,    rect: CGRect(x: 0.0, y: 0.80, width: 1.0, height: 0.20)),
        Zone(name: .deckA,       rect: CGRect(x: 0.0, y: 0.15, width: 0.5, height: 0.65)),
        Zone(name: .deckB,       rect: CGRect(x: 0.5, y: 0.15, width: 0.5, height: 0.65)),
        Zone(name: .bottomStrip, rect: CGRect(x: 0.0, y: 0.00, width: 1.0, height: 0.15)),
    ]

    /// Returns the zone that contains the given normalized position,
    /// or nil if the position falls outside all defined zones.
    static func zone(for position: CGPoint) -> Zone? {
        all.first { $0.contains(position) }
    }
}
