import Testing

@testable import BlurtEngine

@Suite("BlurtIdentity")
struct BlurtIdentityTests {
  @Test("the reverse-DNS identity matches the value scripts hard-code")
  func subsystemPinned() {
    // `scripts/reset-install.sh` hard-codes the same string for its
    // `defaults`/`security` cleanup (bash can't read this constant), so a drift
    // here would silently break that script's Keychain/log cleanup. Changing
    // this value requires updating the script in the same change.
    #expect(BlurtIdentity.subsystem == "dev.alex.blurt")
  }

  @Test("the Keychain service names match the values scripts hard-code")
  func keychainServicesPinned() {
    // `scripts/reset-install.sh` hard-codes both services for its `security`
    // cleanup, and `APIKeyStore`'s migration relies on the legacy value staying
    // exactly what pre-rename installs wrote. Changing either value requires
    // updating the script in the same change.
    #expect(BlurtIdentity.keychainService == "blurt")
    #expect(BlurtIdentity.legacyKeychainService == "dev.alex.blurt")
  }
}
