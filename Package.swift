// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Holler",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v15)],
    products: [
        .library(name: "HollerCore", targets: ["HollerCore"]),
        .library(name: "HollerCoreTestSupport", targets: ["HollerCoreTestSupport"]),
        .library(name: "HollerTransport", targets: ["HollerTransport"]),
        .library(name: "HollerAudio", targets: ["HollerAudio"]),
        .library(name: "HollerPTT", targets: ["HollerPTT"]),
        .library(name: "HollerFeatures", targets: ["HollerFeatures"]),
    ],
    targets: [
        // Core: pure Swift (Foundation only). Domain types, protocols, state machines, supervisors.
        .target(name: "HollerCore", swiftSettings: strict),
        .target(name: "HollerCoreTestSupport", dependencies: ["HollerCore"], swiftSettings: strict),
        .testTarget(name: "HollerCoreTests", dependencies: ["HollerCore", "HollerCoreTestSupport"], swiftSettings: strict),

        // Adapters: one Apple framework / external system each.
        .target(name: "HollerTransport", dependencies: ["HollerCore"], swiftSettings: strict),
        .testTarget(name: "HollerTransportTests", dependencies: ["HollerTransport", "HollerCoreTestSupport"], swiftSettings: strict),
        .target(name: "HollerAudio", dependencies: ["HollerCore"], swiftSettings: strict),
        .target(name: "HollerPTT", dependencies: ["HollerCore"], swiftSettings: strict),

        // Features: SwiftUI + view models, depend on Core protocols only.
        .target(name: "HollerFeatures", dependencies: ["HollerCore"], swiftSettings: strict),
        .testTarget(name: "HollerFeaturesTests", dependencies: ["HollerFeatures", "HollerCoreTestSupport"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
