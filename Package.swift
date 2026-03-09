// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackpadDJ",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TrackpadDJ",
            path: "Sources/TrackpadDJ"
        )
    ]
)
