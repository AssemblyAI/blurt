import Foundation
import Testing

@testable import BlurtEngine

@Suite("HostIdentity")
struct HostIdentityTests {
  /// A second identity, used to prove the derivations actually read the value
  /// rather than the constants they replaced. Deliberately shares no substring
  /// with Blurt's, so a derivation that still hard-codes "Blurt" can't pass by
  /// coincidence.
  private static let acme = HostIdentity(
    productName: "Acme Voice",
    subsystem: "com.acme.voice",
    keychainService: "acme-voice",
    defaultsPrefix: "AcmeVoice",
    logDirectoryName: "Acme Voice",
    releaseURL: URL(staticString: "https://api.github.com/repos/acme/voice/releases/latest"))

  @Test("the reverse-DNS identity matches the value scripts hard-code")
  func subsystemPinned() {
    // `scripts/reset-install.sh` hard-codes the same string for its
    // `defaults`/`security` cleanup (bash can't read this constant), so a drift
    // here would silently break that script's Keychain/log cleanup. Changing
    // this value requires updating the script in the same change.
    #expect(HostIdentity.blurt.subsystem == "dev.alex.blurt")
  }

  @Test("the Keychain service matches the value scripts hard-code")
  func keychainServicePinned() {
    // `scripts/reset-install.sh` hard-codes the same string for its `security`
    // cleanup (bash can't read this constant), so a drift here would silently
    // break that script's Keychain cleanup. Changing this value requires
    // updating the script in the same change.
    #expect(HostIdentity.blurt.keychainService == "blurt")
  }

  @Test("the debug build's Keychain service matches the value scripts hard-code")
  func devKeychainServicePinned() {
    // Same contract as the shipping service above: `scripts/reset-install.sh`
    // lists this string in `KEYCHAIN_SERVICES`, and bash can't read the
    // constant. Renaming it here means renaming it there in the same change.
    #expect(HostIdentity.blurtDev.keychainService == "blurt-dev")
  }

  /// The whole point of the debug identity, stated as an invariant: a dev build
  /// must not reach the shipping app's Keychain item, and must not gain a second
  /// log subsystem, defaults namespace or log directory in the process — one
  /// subsystem across both builds is what keeps the documented `log show`
  /// predicates valid, and a different defaults prefix would abandon every dev
  /// install's settings for nothing.
  @Test("the debug identity differs from the shipping one only in the Keychain service")
  func devDiffersOnlyInTheKeychainService() {
    #expect(HostIdentity.blurtDev.keychainService != HostIdentity.blurt.keychainService)
    #expect(HostIdentity.blurtDev.subsystem == HostIdentity.blurt.subsystem)
    #expect(HostIdentity.blurtDev.defaultsPrefix == HostIdentity.blurt.defaultsPrefix)
    #expect(HostIdentity.blurtDev.logDirectoryName == HostIdentity.blurt.logDirectoryName)
    #expect(HostIdentity.blurtDev.productName == HostIdentity.blurt.productName)
    #expect(HostIdentity.blurtDev.releaseURL == HostIdentity.blurt.releaseURL)
  }

  @Test("an unconfigured engine is Blurt")
  func defaultsToBlurt() {
    // The whole compatibility claim of making these host-supplied: a host that
    // never calls `configure` behaves exactly as the engine did when they were
    // constants. Read-only, so it doesn't race the suites running alongside it.
    #expect(HostIdentity.current == .blurt)
  }

  @Test("defaults keys are the prefix plus the case's raw value")
  func defaultsKeysComposeFromThePrefix() {
    // Blurt's prefix reproduces the keys already on disk — renaming one abandons
    // every existing user's setting, so this is the on-disk contract, not style.
    #expect(HostIdentity.blurt.defaultsKey("SoundPack") == "BlurtSoundPack")
    #expect(Self.acme.defaultsKey("SoundPack") == "AcmeVoiceSoundPack")
  }

  @Test("log URLs live under the identity's directory in ~/Library/Logs")
  func logURLsFollowTheIdentity() {
    #expect(
      HostIdentity.blurt.logURL("dictations.jsonl").path(percentEncoded: false)
        .hasSuffix("Library/Logs/Blurt/dictations.jsonl"))
    #expect(
      Self.acme.logURL("errors.jsonl").path(percentEncoded: false)
        .hasSuffix("Library/Logs/Acme Voice/errors.jsonl"))
  }

  @Test("loggers and queue labels carry the identity's subsystem")
  func subsystemDerivations() {
    // `Logger` exposes nothing to compare, so the queue label — built from the
    // same field, and the thing a spindump names — is what's assertable here.
    #expect(HostIdentity.blurt.queueLabel("DictationLog") == "dev.alex.blurt.DictationLog")
    #expect(Self.acme.queueLabel("DictationLog") == "com.acme.voice.DictationLog")
  }

  // There is deliberately no test that calls `configure(_:)` and reads the result
  // back. `current` is process-wide and Swift Testing runs suites in parallel, so
  // a test that swapped in a second identity — even for two statements — would be
  // visible to every suite asserting a Blurt-prefixed defaults key, the
  // `Library/Logs/Blurt` path, or "Blurt" in an update alert. Trading those for a
  // two-line `Mutex` round trip would buy coverage with flakes. What the feature
  // actually needs proving is that the *derivations* read the value rather than
  // the constants they replaced, and that is what the tests above do, against a
  // constructed identity that touches nothing shared.
}
