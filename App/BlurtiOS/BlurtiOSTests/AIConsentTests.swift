import Foundation
import Testing

@testable import BlurtiOSCore

/// The consent gate over its own defaults suite, never the app's.
@Suite("AI consent")
struct AIConsentTests {
  private func freshDefaults() throws -> UserDefaults {
    let name = "AIConsentTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("nothing is granted until the user agrees, and agreeing sticks")
  func grant() throws {
    let defaults = try freshDefaults()
    #expect(!AIConsent.isGranted(in: defaults))
    AIConsent.grant(in: defaults)
    #expect(AIConsent.isGranted(in: defaults))
  }

  @Test("agreeing to an older disclosure doesn't cover the current one")
  func olderVersion() throws {
    let defaults = try freshDefaults()
    defaults.set(AIConsent.version - 1, forKey: AIConsent.defaultsKey)
    #expect(!AIConsent.isGranted(in: defaults))
  }

  @Test("the privacy policy link is AssemblyAI's")
  func privacyPolicy() {
    #expect(AIConsent.privacyPolicyURL.host() == "www.assemblyai.com")
  }
}
