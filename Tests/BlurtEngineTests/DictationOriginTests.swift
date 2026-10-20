import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A signed-in key dictates against the host its sign-in configured; anything
/// else goes to production.
@Suite("Dictation origin")
struct DictationOriginTests {
  private static let sandbox = URL(literal: "https://dictation.sandbox.example.com")

  /// Records the host of every request it answers.
  private final class Hosts: Sendable {
    let seen = Mutex<[String]>([])
    var transport: FakeHTTPTransport {
      FakeHTTPTransport { [self] request in
        seen.withLock { $0.append(request.url?.host() ?? "?") }
        return (200, json(["text": "hi"]))
      }
    }
  }

  @Test("the transcriber reads its host per request: the origin while it holds one, else the default")
  func transcriberFollowsTheOrigin() async throws {
    let hosts = Hosts()
    let origin = DictationOrigin()
    let transcriber = AssemblyAITranscriber(
      apiKeyProvider: { "key" }, baseURL: { origin.current ?? AssemblyAITranscriber.defaultBaseURL },
      transport: hosts.transport,
      enhancedTranscripts: { false }, customStyle: { nil }, rewriteMode: { .fast })

    _ = try await collectTranscript(transcriber)
    origin.set(Self.sandbox)
    await transcriber.warmUp()
    _ = try await collectTranscript(transcriber)
    origin.set(nil)
    _ = try await collectTranscript(transcriber)

    #expect(
      hosts.seen.withLock { $0 } == [
        "dictation.assemblyai.com", "dictation.sandbox.example.com", "dictation.sandbox.example.com",
        "dictation.assemblyai.com",
      ])
  }

  @Test("the setting parses like the other sign-in URLs, and is optional")
  func setting() {
    let key = OAuthConfiguration.InfoKey.dictationOrigin
    #expect(
      OAuthConfiguration.blurtDictationOrigin(infoDictionary: [key: "https://dictation.sandbox.example.com"])
        == Self.sandbox)
    #expect(OAuthConfiguration.blurtDictationOrigin(infoDictionary: [key: "http://localhost:8080"]) != nil)
    for unset: Any in ["", " ", "http://dictation.example.com", 42] {
      #expect(OAuthConfiguration.blurtDictationOrigin(infoDictionary: [key: unset]) == nil)
    }
    #expect(OAuthConfiguration.blurtDictationOrigin(infoDictionary: [:]) == nil)
  }
}

extension AssemblyAIAccountTests {
  @Test("the account's dictation origin is its host while signed in, and nil once signed out")
  func dictationOriginFollowsSignIn() async throws {
    let host = URL(literal: "https://dictation.sandbox.example.com")
    let clock = clock
    func account() -> AssemblyAIAccount {
      AssemblyAIAccount(
        configuration: testOAuthConfiguration, dictationHost: host,
        apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
        store: sessions, transport: server.transport, now: { clock.now })
    }
    let first = account()
    #expect(first.dictationOrigin.current == nil)

    let auth = try #require(first.beginSignIn())
    let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
    #expect(await first.completeSignIn(auth, callback: callback) == .signedIn)
    #expect(first.dictationOrigin.current == host)

    // A relaunch reads the stored session and starts on the sign-in's host.
    #expect(account().dictationOrigin.current == host)

    #expect(await first.signOut() == nil)
    #expect(first.dictationOrigin.current == nil)
  }

  @Test("a sign-in that configures no dictation host leaves dictation on production")
  func noDictationHost() async throws {
    let account = try await signedIn()
    #expect(account.status != .signedOut)
    #expect(account.dictationOrigin.current == nil)
  }
}
