// swift-tools-version:6.2
import PackageDescription

// The strictest checking this toolchain offers, on every target, tests included.
// Each entry adds diagnostics and nothing else: the code compiles to exactly
// what it did before, it just has to say more about itself to get there.
//
// Swift 6 language mode (swift-tools 6.2) already turns on every upcoming
// feature `swiftc -frontend -print-supported-features` lists as `enabled_in: 6`
// (StrictConcurrency, GlobalConcurrency, RegionBasedIsolation,
// DynamicActorIsolation, ...). What's listed below is the strictness half of
// the `enabled_in: 7` set, plus the opt-in modes.
//
// Deliberately NOT enabled, because each changes what the code does at run
// time rather than what the compiler checks:
// - NonisolatedNonsendingByDefault (SE-0461): moves where every nonisolated
//   async function runs, from the global executor onto the caller's actor.
// - Default MainActor isolation (SE-0466, `.defaultIsolation(MainActor.self)`):
//   would put the whole engine, its audio and network paths included, on the
//   main thread. The iPhone targets use it; a library serving both apps must not.
// - ApproachableConcurrency: an umbrella over the two above (plus
//   InferIsolatedConformances, enabled here on its own).
// - `-enable-actor-data-race-checks`: inserts run-time traps, and Swift 6 mode's
//   DynamicActorIsolation already checks isolation at the synchronous entry
//   points it would.
// The experimental features this toolchain lists are ownership, layout,
// interop and macro work, none of them a check; GroupActorErrors only regroups
// existing diagnostics, so it adds none.
//
// scripts/ios-typecheck.sh passes the same list to swiftc for the engine's iOS
// shape; change both together.
let strictSettings: [SwiftSetting] = [
  // SE-0335: an existential spells out `any`, so its cost is visible.
  .enableUpcomingFeature("ExistentialAny"),
  // SE-0444: a member is visible only in a file that imports its module.
  .enableUpcomingFeature("MemberImportVisibility"),
  // SE-0409: every import is internal unless it says otherwise, so a type a
  // public API re-exports needs a `public import` that says so.
  .enableUpcomingFeature("InternalImportsByDefault"),
  // SE-0470: a global-actor-isolated type's conformances are inferred to share
  // its isolation; one that must stay nonisolated says `nonisolated`.
  .enableUpcomingFeature("InferIsolatedConformances"),
  // SE-0481: a `weak` capture is a `let`, so it can't be reassigned in the closure.
  .enableUpcomingFeature("ImmutableWeakCaptures"),
  // SE-0458: every use of an unsafe pointer, buffer or `nonisolated(unsafe)` is
  // acknowledged with `unsafe` at the site.
  .strictMemorySafety(),
  // SE-0480: the build fails on any warning, not only under check.sh's flag.
  .treatAllWarnings(as: .error),
  // A public type says whether it is Sendable rather than leaving it implied.
  // The type-checking thresholds fail a function body or expression that takes
  // the type checker over 500 ms: the slowest today is under 200 ms on an M-series
  // Mac, so the headroom covers a slower CI runner, and an expression that needs
  // more is one to split.
  .unsafeFlags([
    "-require-explicit-sendable",
    "-Xfrontend", "-warn-long-function-bodies=500",
    "-Xfrontend", "-warn-long-expression-type-checking=500",
  ]),
]

let package = Package(
  name: "BlurtEngine",
  // iOS 18 is the era-matching floor for macOS 15: the engine's `Synchronization`
  // imports (`Mutex`) need it, and nothing portable here wants anything newer.
  // The macOS-only capture, injection, Accessibility and TCC files are fenced
  // behind `#if os(macOS)`; the pipeline, STT client and settings stores compile
  // for both platforms. CI's `ios-build` job is what keeps that true.
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "BlurtEngine", targets: ["BlurtEngine"]),
    // The AssemblyAI API client the engine is built on: transport, wire types,
    // key validation. Foundation only, no Blurt policy, so it can become a
    // standalone SDK. See Sources/AssemblyAI/README.md.
    .library(name: "AssemblyAI", targets: ["AssemblyAI"]),
  ],
  targets: [
    .target(
      name: "AssemblyAI",
      exclude: ["README.md"],
      swiftSettings: strictSettings
    ),
    .target(
      name: "BlurtEngine",
      dependencies: ["AssemblyAI"],
      // The engine's developer guide lives next to the code it documents. SwiftPM
      // has no rule for a stray .md inside a target, so declare it excluded rather
      // than let it land in the target's unhandled-files list.
      exclude: ["README.md"],
      swiftSettings: strictSettings
    ),
    // The window the live performer suite acts on (`LivePerformerTests`, gated
    // on BLURT_LIVE_AX_TESTS=1): a test dependency so `swift test` builds it,
    // never a product, and never linked into the app.
    .executableTarget(
      name: "CommandFixture",
      path: "Tests/CommandFixture",
      swiftSettings: strictSettings
    ),
    .testTarget(
      name: "BlurtEngineTests",
      dependencies: ["BlurtEngine", "AssemblyAI", "CommandFixture"],
      swiftSettings: strictSettings
    ),
  ]
)
