import Foundation
import Testing

@testable import BlurtEngine

/// The auto-record policy and what counts as a meeting.
@Suite("Meeting auto-record")
struct MeetingAutoRecordTests {
  private let start = ContinuousClock.now

  private func at(_ seconds: Int) -> ContinuousClock.Instant { start + .seconds(seconds) }

  @Test("starts on the first probe that sees a meeting")
  func startsAtOnce() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: nil, recording: false, autoStart: true, now: at(0)) == .none)
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(5)) == .start)
  }

  @Test("a browser meeting stops only after a minute gone straight; a return resets it")
  func hysteresis() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(0)) == .start)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(10)) == .none)
    #expect(policy.probe(meeting: .browser, recording: true, autoStart: true, now: at(30)) == .none)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(40)) == .none)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(99)) == .none)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(100)) == .stop)
  }

  @Test("a conferencing app's meeting stops fifteen seconds after it lets go")
  func appStopsSooner() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(0)) == .start)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(10)) == .none)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(24)) == .none)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(25)) == .stop)
  }

  @Test("never stops a recording the user started")
  func leavesManualRecordings() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(0)) == .none)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(120)) == .none)
  }

  @Test("a user stop mid-meeting holds off until that meeting ends")
  func userStopSuppresses() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(0)) == .start)
    policy.userStopped(meetingActive: true)
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(5)) == .none)
    #expect(policy.probe(meeting: nil, recording: false, autoStart: true, now: at(10)) == .none)
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(15)) == .start)
  }

  @Test("a recording started by hand during a meeting ends with it, switch on or off")
  func userStartDuringMeetingBinds() {
    for autoStart in [true, false] {
      var policy = MeetingAutoRecord()
      policy.userStarted()
      #expect(policy.probe(meeting: .app, recording: true, autoStart: autoStart, now: at(0)) == .none)
      #expect(policy.probe(meeting: nil, recording: true, autoStart: autoStart, now: at(10)) == .none)
      #expect(policy.probe(meeting: nil, recording: true, autoStart: autoStart, now: at(70)) == .stop)
    }
  }

  @Test("a recording started by hand with no meeting on isn't ended by a call during it")
  func userStartWithoutMeetingStaysUnbound() {
    var policy = MeetingAutoRecord()
    policy.userStarted()
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(0)) == .none)
    #expect(policy.probe(meeting: .app, recording: true, autoStart: true, now: at(10)) == .none)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(20)) == .none)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(200)) == .none)
  }

  @Test("with the switch off it never starts a recording")
  func switchOffNeverStarts() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: .app, recording: false, autoStart: false, now: at(0)) == .none)
  }

  @Test("meeting apps and browsers count; other mic users and Blurt don't")
  func whatCounts() {
    #expect(MeetingAutoRecord.meeting(in: ["us.zoom.xos"]) == .app)
    #expect(MeetingAutoRecord.meeting(in: ["us.zoom.CptHost"]) == .app)
    #expect(MeetingAutoRecord.meeting(in: ["com.microsoft.teams2", "com.apple.Music"]) == .app)
    #expect(MeetingAutoRecord.meeting(in: ["com.google.Chrome"]) == .browser)
    #expect(MeetingAutoRecord.meeting(in: ["com.google.Chrome", "us.zoom.xos"]) == .app)
    #expect(MeetingAutoRecord.meeting(in: ["dev.alex.blurt", "com.apple.VoiceMemos"]) == nil)
    #expect(MeetingAutoRecord.meeting(in: []) == nil)
  }

  @Test("the switch is off unless set")
  func storeDefaultsOff() throws {
    let defaults = try #require(UserDefaults(suiteName: "MeetingAutoRecordTests-\(UUID())"))
    #expect(!MeetingAutoRecordStore(defaults: defaults).isEnabled)
    defaults.set(true, forKey: MeetingAutoRecordStore.defaultsKey)
    #expect(MeetingAutoRecordStore(defaults: defaults).isEnabled)
  }
}
