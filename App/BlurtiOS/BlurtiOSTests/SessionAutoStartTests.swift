import Foundation
import Testing

@testable import BlurtiOSCore

/// The session's on-by-default rule, over its own defaults suite, never the app's.
@Suite("Session auto-start")
struct SessionAutoStartTests {
  private func freshDefaults() throws -> UserDefaults {
    let name = "SessionAutoStartTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private func starts(
    open: Bool = false, key: Bool = true, consent: Bool = true, mic: Bool = true, off: Bool = false
  ) -> Bool {
    SessionAutoStart.shouldStart(windowOpen: open, hasKey: key, consented: consent, micGranted: mic, turnedOff: off)
  }

  @Test("on by itself only when nothing needs asking and the user hasn't turned it off")
  func shouldStart() {
    #expect(starts())
    #expect(!starts(open: true))
    #expect(!starts(key: false))
    #expect(!starts(consent: false))
    #expect(!starts(mic: false))
    #expect(!starts(off: true))
  }

  @Test("off by the switch sticks until the user asks for a session again")
  func turnedOff() throws {
    let defaults = try freshDefaults()
    #expect(!SessionAutoStart.isTurnedOff(in: defaults))
    SessionAutoStart.setTurnedOff(true, in: defaults)
    #expect(SessionAutoStart.isTurnedOff(in: defaults))
    SessionAutoStart.setTurnedOff(false, in: defaults)
    #expect(!SessionAutoStart.isTurnedOff(in: defaults))
  }
}
