import Testing

@testable import BlurtEngine

@Suite("BlurtIdentity")
struct BlurtIdentityTests {
  @Test("the reverse-DNS identity matches the value scripts hard-code")
  func subsystemPinned() {
    // `scripts/reset-install.sh` hard-codes the same string for its
    // `defaults`/`tccutil` cleanup (bash can't read this constant), so a drift
    // here would silently break that script's TCC/defaults cleanup. Changing
    // this value requires updating the script in the same change.
    #expect(BlurtIdentity.subsystem == "dev.alex.blurt")
  }

  @Test("the Keychain service is the product name, not the reverse-DNS id")
  func keychainServicePinned() {
    // Keychain Access shows the service as the item's name, so this is what a
    // user auditing their keychain reads. `scripts/reset-install.sh` hard-codes
    // it as well.
    #expect(BlurtIdentity.keychainService == "Blurt")
  }

  @Test("the legacy Keychain service still names the item shipped builds wrote")
  func legacyKeychainServicePinned() {
    // Installs from before the rename saved the key under the bundle id.
    // `MigratingKeychainStore` reads this service to adopt that key, so changing
    // it strands every existing user's saved key.
    #expect(BlurtIdentity.legacyKeychainService == "dev.alex.blurt")
  }
}
