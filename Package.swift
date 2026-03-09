// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackpadDJ",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CRubberBand",
            path: "Sources/CRubberBand"
        ),
        .executableTarget(
            name: "TrackpadDJ",
            dependencies: ["CRubberBand"],
            path: "Sources/TrackpadDJ",
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"])
            ]
        )
    ]
)
