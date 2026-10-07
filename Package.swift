// swift-tools-version: 6.2
import PackageDescription

// The code compiles in the Swift 5 language mode, with the concurrency features
// of Swift 6 that it already follows. Every type is on the main actor unless it
// says otherwise.
let swiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5),
  .defaultIsolation(MainActor.self),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("DisableOutwardActorInference"),
  .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
  .enableUpcomingFeature("InferSendableFromCaptures"),
]

let package = Package(
  name: "macshot",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "macshot", targets: ["macshot"])
  ],
  targets: [
    .executableTarget(
      name: "macshot",
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "macshotTests",
      dependencies: ["macshot"],
      swiftSettings: swiftSettings
    ),
  ]
)
