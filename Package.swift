// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "BlurtEngine",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "BlurtEngine", targets: ["BlurtEngine"])
  ],
  targets: [
    .target(
      name: "BlurtEngine",
      // The engine's developer guide lives next to the code it documents. SwiftPM
      // has no rule for a stray .md inside a target, so declare it excluded rather
      // than let it land in the target's unhandled-files list.
      exclude: ["README.md"]
    ),
    .testTarget(
      name: "BlurtEngineTests",
      dependencies: ["BlurtEngine"]
    ),
  ]
)
