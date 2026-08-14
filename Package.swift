// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "BlurtEngine",
  // iOS 18 is the era-matching floor for macOS 15: the engine's `Synchronization`
  // imports (Mutex) need it, and nothing portable here wants anything newer. The
  // mac-only capture/injection/AX files are fenced behind `#if os(macOS)`; the
  // pipeline, STT client, and settings stores compile for both platforms.
  platforms: [.macOS(.v15), .iOS(.v18)],
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
