// swift-tools-version: 6.2
import PackageDescription

// The code compiles in the Swift 6 language mode. Every type is on the main
// actor unless it says otherwise.
let swiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .defaultIsolation(MainActor.self),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
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
