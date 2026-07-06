// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "BlurtEngine",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "BlurtEngine", targets: ["BlurtEngine"])
  ],
  targets: [
    .target(
      name: "BlurtEngine"
    ),
    .testTarget(
      name: "BlurtEngineTests",
      dependencies: ["BlurtEngine"]
    ),
  ]
)
