import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

// When the account renews: on the server's rotation time, sleeping until then,
// at once when dictation refuses the key, and never in a loop.
extension AssemblyAIAccountTests {
  @Test("runRenewal sleeps until the renewal is due, renews, and stops when cancelled")
  func runRenewal() async throws {
    let account = try await signedIn()
    let testClock = TestClock()
    let loop = Task { await account.runRenewal(clock: testClock) }
    advanceToRenewal()
    // The first check ran before the date moved to the renewal, or after:
    // either way, advancing virtual time past the longest sleep drives one more.
    for _ in 0..<50 where server.state.withLock({ $0.refreshTokensSeen }).isEmpty {
      testClock.advance(by: .seconds(AssemblyAIAccount.longestRenewalSleep))
      await Task.yield()
    }
    #expect(server.state.withLock { $0.refreshTokensSeen } == ["rt-1"])
    loop.cancel()
    await loop.value
  }

  @Test("the loop sleeps until the renewal is due, within the shortest and longest sleep")
  func nextRenewalCheck() async throws {
    let signedOut = account()
    #expect(signedOut.nextRenewalCheck() == AssemblyAIAccount.longestRenewalSleep)

    let account = try await signedIn()
    // The fake key expires weeks away: the longest sleep, then look again.
    #expect(account.nextRenewalCheck() == AssemblyAIAccount.longestRenewalSleep)
    let due = try #require(sessions.session).renewalDue
    clock.advance(due.timeIntervalSince(clock.now) - 3_600)
    #expect(account.nextRenewalCheck() == 3_600)
    clock.advance(7_200)
    #expect(account.nextRenewalCheck() == AssemblyAIAccount.shortestRenewalSleep)
  }

  @Test("a rejected key renews at once, at most once per spacing, and only for a sign-in")
  func keyWasRejected() async throws {
    keyStore.save("pasted")
    let pasted = account()
    await pasted.keyWasRejected()
    #expect(server.state.withLock { $0.refreshTokensSeen }.isEmpty)

    let account = try await signedIn()
    await account.keyWasRejected()
    #expect(server.state.withLock { $0.refreshTokensSeen } == ["rt-1"])
    await account.keyWasRejected()
    #expect(server.state.withLock { $0.refreshTokensSeen }.count == 1)
    clock.advance(AssemblyAIAccount.rejectedKeyRenewalSpacing)
    await account.keyWasRejected()
    #expect(server.state.withLock { $0.refreshTokensSeen } == ["rt-1", "rt-2"])
  }

  @Test("a rejected key whose connection was ended signs the account out")
  func keyWasRejectedEndsTheConnection() async throws {
    let account = try await signedIn()
    server.state.withLock { $0.exchangeStatus = 403 }
    await account.keyWasRejected()
    #expect(account.status == .signedOut)
    #expect(keyStore.current == nil)
  }

  @Test("renewal is scheduled for when the server says the key rotates")
  func schedulesFromRotatesAt() async throws {
    server.state.withLock { $0.rotatesAt = "2026-10-25T00:00:00Z" }
    _ = try await signedIn()
    #expect(sessions.session?.renewalDue == Date(timeIntervalSince1970: 1_793_491_200 - 7 * 86_400))
  }

  @Test("a renewal that brings back the same key waits for its expiry, not a minute")
  func loopGuard() async throws {
    // The fake server never rotates early and doesn't say when it rotates.
    let account = try await signedIn()
    let expiry = Date(timeIntervalSince1970: 1_793_491_200)
    advanceToRenewal()
    await account.renewIfDue()
    #expect(server.state.withLock { $0.refreshTokensSeen } == ["rt-1"])
    #expect(sessions.session?.renewalDue == expiry)
    #expect(account.nextRenewalCheck() == AssemblyAIAccount.longestRenewalSleep)

    // At expiry the same key again (a server that won't rotate at all): a day out.
    clock.advance(expiry.timeIntervalSince(clock.now))
    await account.renewIfDue()
    #expect(sessions.session?.renewalDue == clock.now.addingTimeInterval(SignInSession.unknownExpiryInterval))
  }
}
