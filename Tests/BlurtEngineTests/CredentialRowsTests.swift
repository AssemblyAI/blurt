import Foundation
import Security
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtAssemblyAI
@testable import BlurtEngine

@Suite("Credential rows")
struct CredentialRowsTests {
  @Test("a new install with sign-in configured: one row offering both ways in")
  func newInstallChooses() {
    #expect(CredentialRows.resolve(isKeyStored: false, isSignInAvailable: true, status: .signedOut) == .choice)
  }

  @Test("a pasted key is the whole connection: just the key row, no Sign In beside it to read as a step")
  func pastedKeyStandsAlone() {
    #expect(
      CredentialRows.resolve(isKeyStored: true, isSignInAvailable: true, status: .signedOut)
        == .keyRow(connectIsPrimary: false))
  }

  @Test("no sign-in configured: just the key row, Connect filled until a key is stored")
  func withoutSignIn() {
    #expect(
      CredentialRows.resolve(isKeyStored: false, isSignInAvailable: false, status: .signedOut)
        == .keyRow(connectIsPrimary: true))
    #expect(
      CredentialRows.resolve(isKeyStored: true, isSignInAvailable: false, status: .signedOut)
        == .keyRow(connectIsPrimary: false))
  }

  @Test("signed in: the account row alone, even where sign-in isn't configured")
  func signedIn() {
    for available in [true, false] {
      #expect(
        CredentialRows.resolve(isKeyStored: true, isSignInAvailable: available, status: .signedIn(email: nil))
          == .accountRow)
    }
  }
}
