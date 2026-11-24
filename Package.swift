// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "gifshot",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "gifshot",
            path: "Sources/gifshot",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        )
    ]
)
