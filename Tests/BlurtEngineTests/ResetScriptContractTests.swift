import Foundation
import Testing

@testable import BlurtEngine

/// `scripts/reset-lib.sh` hard-codes the names Blurt stores things under — bash
/// can't read the Swift constants — so a rename here would leave the terminal
/// reset quietly sweeping the old names. This reads the script and holds it to
/// the constants instead of trusting a comment to keep them in step.
@Suite("Reset script contract")
struct ResetScriptContractTests {
  private static let script: String = {
    let url = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "scripts/reset-lib.sh")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }()

  @Test("the subsystem, the release bundle id the dev id derives from")
  func subsystem() {
    #expect(Self.script.contains("BLURT_SUBSYSTEM=\"\(HostIdentity.blurt.subsystem)\""))
  }

  @Test("both builds' Keychain services")
  func keychainServices() {
    for service in [HostIdentity.blurt.keychainService, HostIdentity.blurtDev.keychainService] {
      #expect(Self.script.contains("\"\(service)\""), "\(service)")
    }
  }

  @Test("the dev build's Library folder, the one the dev reset empties")
  func devLibrary() {
    #expect(Self.script.contains("Application Support/\(HostIdentity.blurtDev.dataDirectoryName)\""))
  }

  @Test("the key's and the sign-in session's Keychain accounts")
  func keychainAccounts() {
    #expect(
      Self.script.contains(
        "BLURT_KEYCHAIN_ACCOUNTS=(\"\(APIKeyStore.keychainAccount)\" \"\(SignInStore.keychainAccount)\")"))
  }
}
