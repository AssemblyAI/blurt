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
}
