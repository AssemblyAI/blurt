import Foundation
import Synchronization
import os

/// Everything the engine needs to know about *which app it is running inside*:
/// the Keychain item the API key lands in, the unified-logging subsystem, the
/// `UserDefaults` key prefix, the directory under `~/Library/Logs` the
/// developer-mode logs are written to, the product name user-facing copy says,
/// and the GitHub release the update check reads.
///
/// These used to be hard constants, which made them Blurt's with no opt-out: a
/// second app embedding the engine wrote into *Blurt's* Keychain item, log
/// directory and defaults keys. They are one value now, and every engine
/// component reads `HostIdentity.current`, so a host overrides all of them with a
/// single `configure(_:)` at its composition root — or inherits `.blurt` by doing
/// nothing, which is what keeps this repo's own behaviour byte-for-byte
/// unchanged.
///
/// A process-wide value rather than a parameter threaded through every
/// initializer, because the things that read it are not objects a caller
/// constructs: `static let` loggers, an enum of defaults keys, a Keychain facade.
/// Injecting it would have meant an identity parameter on every store, view and
/// test in the repo to configure something that is, by definition, fixed for the
/// lifetime of a process.
public struct HostIdentity: Sendable, Equatable {
  /// The product name as it appears in user-facing copy ("Blurt") — distinct
  /// from `subsystem`, which is the reverse-DNS identity. `UpdateAlertContent`
  /// is its only reader today.
  public let productName: String

  /// Reverse-DNS identity ("dev.alex.blurt"): the `os_log` subsystem for every
  /// category, and the prefix for the engine's dispatch-queue labels. For Blurt
  /// this must match `BUNDLE_ID` in `scripts/reset-install.sh`, which hard-codes
  /// the same value for its `defaults`/`tccutil` cleanup (bash can't read this
  /// constant).
  ///
  /// It is also Blurt's **release** bundle id, but is not interchangeable with
  /// the running one: debug builds ship under `dev.alex.blurt.dev` so a dev
  /// install is a separate app to macOS (see `project.yml`). One log subsystem
  /// across both is deliberate — the documented `log show` predicates stay valid
  /// whichever build is running — but anything addressing *this process's*
  /// container, defaults domain or TCC records must read
  /// `Bundle.main.bundleIdentifier` instead.
  public let subsystem: String

  /// The Keychain service for the API key item. Blurt uses the plain app name,
  /// so the entry appears as "blurt" in Keychain Access instead of a
  /// developer-domain string; it must match one of the `KEYCHAIN_SERVICES` in
  /// `scripts/reset-install.sh`.
  ///
  /// **This is the one store the debug/release split doesn't separate for
  /// free.** Keychain items are per *login keychain*, not per app, so both
  /// builds resolved the same `blurt` item however different their bundle ids
  /// were: a dev build read the shipping app's key, could overwrite it, and — once
  /// Settings grew a Reset — could delete it. `.blurtDev` gives the debug build
  /// its own item; `BlurtApp.init` picks between the two by the running bundle
  /// id.
  ///
  /// This is the one gap a host could already work around before the identity
  /// existed — compose against `APIKeyGateway` with your own conformance instead
  /// of `ProductionAPIKeyStore` and the service never comes up — but overriding
  /// it here means `APIKeyStore` itself is usable as shipped.
  public let keychainService: String

  /// Prefixed onto every `DefaultsKey` raw value to form the key actually
  /// written (`"Blurt"` + `"SoundPack"`). The prefix is what separates the
  /// engine's settings from anything else sharing the host's defaults domain, so
  /// two apps embedding the engine no longer collide on `BlurtSoundPack`.
  ///
  /// **On-disk contract.** Changing this for an app that has already shipped
  /// abandons every existing user's settings exactly as renaming a `DefaultsKey`
  /// raw value would — pick it once, at the point the host is first published.
  public let defaultsPrefix: String

  /// The directory under `~/Library/Logs` the developer-mode dictation and error
  /// logs are written to (`~/Library/Logs/Blurt/{dictations,errors}.jsonl`).
  public let logDirectoryName: String

  /// The "latest release" endpoint `UpdateChecker` reads, and therefore the repo
  /// whose DMG the update alert offers. Still an initializer parameter on
  /// `UpdateChecker` (tests substitute a local URL); this is the default a host
  /// gets without passing one.
  public let releaseURL: URL

  public init(
    productName: String,
    subsystem: String,
    keychainService: String,
    defaultsPrefix: String,
    logDirectoryName: String,
    releaseURL: URL
  ) {
    self.productName = productName
    self.subsystem = subsystem
    self.keychainService = keychainService
    self.defaultsPrefix = defaultsPrefix
    self.logDirectoryName = logDirectoryName
    self.releaseURL = releaseURL
  }

  /// Blurt's own identity, and the value an unconfigured host inherits — so the
  /// engine behaves exactly as it did when these were constants. It is the single
  /// definition of each of those strings; `App.swift` configures *this* value
  /// rather than restating them, and `HostIdentityTests` pins the two that
  /// `scripts/reset-install.sh` also hard-codes.
  public static let blurt = HostIdentity(
    productName: "Blurt",
    subsystem: "dev.alex.blurt",
    keychainService: "blurt",
    defaultsPrefix: "Blurt",
    logDirectoryName: "Blurt",
    releaseURL: URL(
      staticString: "https://api.github.com/repos/AssemblyAI/blurt/releases/latest"))

  /// The identity a **debug build** of Blurt runs under — "Blurt Dev", which
  /// macOS already treats as a separate app (its own bundle id, TCC rows and
  /// defaults domain). Only `keychainService` differs from `.blurt`, because the
  /// Keychain is the only store that isn't separated by the bundle id already
  /// (see that property).
  ///
  /// The log subsystem is deliberately *not* changed: one subsystem across both
  /// builds is what keeps the documented `log show` predicates valid whichever
  /// one is running (see `subsystem`). Nor is `defaultsPrefix` — defaults are
  /// per-app already, and changing the prefix would abandon every dev install's
  /// settings for nothing.
  ///
  /// `scripts/reset-install.sh` hard-codes this service alongside the shipping
  /// one (bash can't read this constant); `HostIdentityTests` pins both.
  public static let blurtDev = blurt.withKeychainService("blurt-dev")

  /// This identity with a different Keychain service. Private: the two values
  /// Blurt ships are the two above, and a host that wants a third builds it with
  /// the initializer rather than deriving one from Blurt's.
  private func withKeychainService(_ service: String) -> HostIdentity {
    HostIdentity(
      productName: productName,
      subsystem: subsystem,
      keychainService: service,
      defaultsPrefix: defaultsPrefix,
      logDirectoryName: logDirectoryName,
      releaseURL: releaseURL)
  }

  /// The identity every engine component reads. `.blurt` until a host calls
  /// `configure(_:)`.
  public static var current: HostIdentity { storage.withLock { $0 } }

  /// Adopt `identity` for the rest of the process. **Call this once, at your
  /// composition root, before constructing any engine type** (Blurt does it in
  /// `BlurtApp.init`).
  ///
  /// The ordering is a real requirement, not politeness: the readers are lazily
  /// initialized `static let`s — loggers, the log-append queue, `APIKeyStore`'s
  /// memoized Keychain item — so one that was touched before this call keeps the
  /// identity it resolved with. There is deliberately no enforcement of that:
  /// trapping on a second call would make the engine unusable from a test that
  /// wants to exercise two identities, and refusing the second call silently
  /// would be worse than the misconfiguration it was guarding against.
  public static func configure(_ identity: HostIdentity) {
    storage.withLock { $0 = identity }
  }

  /// `Mutex` rather than a `nonisolated(unsafe) var`, for the reason
  /// `MemoizedKeyStore` and `APIKeyGateway` use one: this is read from every
  /// isolation domain in the engine (the `DictationSession` actor, the log's
  /// serial queue, `@MainActor` views) and a torn read of a struct this size is
  /// not hypothetical.
  private static let storage = Mutex<HostIdentity>(.blurt)

  // MARK: - Derivations
  //
  // Pure functions of the value, so the tests exercise them against a
  // constructed `HostIdentity` rather than by mutating the process-wide one —
  // which, being process-wide, would race every other suite reading `current`.

  /// The `UserDefaults` key a `DefaultsKey` case writes: the prefix, then the
  /// case's raw value.
  func defaultsKey(_ suffix: String) -> String { defaultsPrefix + suffix }

  /// `~/Library/Logs/<logDirectoryName>/<fileName>` — where the developer-mode
  /// logs land. Neither the directory nor the file is created by asking.
  func logURL(_ fileName: String) -> URL {
    URL.libraryDirectory.appending(path: "Logs/\(logDirectoryName)/\(fileName)")
  }

  /// A `Logger` on this identity's subsystem. Spelled once here so the engine's
  /// loggers don't each restate `subsystem:` — and public because the host's own
  /// components want the same subsystem, so their lines show up under the
  /// documented `log show` predicates too (Blurt's `DictationKeyTap` and
  /// `UpdateCheckModel` are the in-repo examples).
  public func logger(_ category: String) -> Logger {
    Logger(subsystem: subsystem, category: category)
  }

  /// A dispatch-queue label under this identity's reverse-DNS prefix, matching
  /// what the queues were named when the prefix was a constant.
  func queueLabel(_ name: String) -> String { "\(subsystem).\(name)" }
}
