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
    #expect(policy.probe(meeting: nil, recording: false, autoStart: true, now: at(0)) == .noChange)
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(5)) == .start)
  }

  @Test("a browser call starts a recording only once it's been on thirty seconds straight")
  func browserStartsLate() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(0)) == .noChange)
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(25)) == .noChange)
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(30)) == .start)
  }

  @Test("a browser that lets go of the mic before then starts nothing, and starts the clock over")
  func briefBrowserMicIgnored() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(0)) == .noChange)
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(5)) == .noChange)
    #expect(policy.probe(meeting: nil, recording: false, autoStart: true, now: at(10)) == .noChange)
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(35)) == .noChange)
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(64)) == .noChange)
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(65)) == .start)
  }

  @Test("a conferencing app taking over from a browser starts at once")
  func appOverridesBrowserWait() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(0)) == .noChange)
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(5)) == .start)
  }

  @Test("a browser meeting stops only after a minute gone straight; a return resets it")
  func hysteresis() {
    var policy = MeetingAutoRecord(browserStartAfter: .zero)
    #expect(policy.probe(meeting: .browser, recording: false, autoStart: true, now: at(0)) == .start)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(10)) == .noChange)
    #expect(policy.probe(meeting: .browser, recording: true, autoStart: true, now: at(30)) == .noChange)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(40)) == .noChange)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(99)) == .noChange)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(100)) == .stop)
  }

  @Test("a conferencing app's meeting stops fifteen seconds after it lets go")
  func appStopsSooner() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(0)) == .start)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(10)) == .noChange)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(24)) == .noChange)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(25)) == .stop)
  }

  @Test("never stops a recording the user started")
  func leavesManualRecordings() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(0)) == .noChange)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(120)) == .noChange)
  }

  @Test("a user stop mid-meeting holds off until that meeting ends")
  func userStopSuppresses() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(0)) == .start)
    policy.userStopped(meetingActive: true)
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(5)) == .noChange)
    #expect(policy.probe(meeting: nil, recording: false, autoStart: true, now: at(10)) == .noChange)
    #expect(policy.probe(meeting: .app, recording: false, autoStart: true, now: at(15)) == .start)
  }

  @Test("a recording started by hand during a meeting ends with it, switch on or off")
  func userStartDuringMeetingBinds() {
    for autoStart in [true, false] {
      var policy = MeetingAutoRecord()
      policy.userStarted()
      #expect(policy.probe(meeting: .app, recording: true, autoStart: autoStart, now: at(0)) == .noChange)
      #expect(policy.probe(meeting: nil, recording: true, autoStart: autoStart, now: at(10)) == .noChange)
      #expect(policy.probe(meeting: nil, recording: true, autoStart: autoStart, now: at(70)) == .stop)
    }
  }

  @Test("a recording started by hand with no meeting on isn't ended by a call during it")
  func userStartWithoutMeetingStaysUnbound() {
    var policy = MeetingAutoRecord()
    policy.userStarted()
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(0)) == .noChange)
    #expect(policy.probe(meeting: .app, recording: true, autoStart: true, now: at(10)) == .noChange)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(20)) == .noChange)
    #expect(policy.probe(meeting: nil, recording: true, autoStart: true, now: at(200)) == .noChange)
  }

  @Test("with the switch off it never starts a recording")
  func switchOffNeverStarts() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meeting: .app, recording: false, autoStart: false, now: at(0)) == .noChange)
  }

  @Test("meeting apps and two-way browser audio count; other mic users and Blurt don't")
  func whatCounts() {
    #expect(MeetingAutoRecord.meeting(in: ["us.zoom.xos"], playing: []) == .app)
    #expect(MeetingAutoRecord.meeting(in: ["us.zoom.CptHost"], playing: []) == .app)
    #expect(MeetingAutoRecord.meeting(in: ["com.microsoft.teams2", "com.apple.Music"], playing: []) == .app)
    #expect(MeetingAutoRecord.meeting(in: ["com.google.Chrome"], playing: ["com.google.Chrome"]) == .browser)
    #expect(MeetingAutoRecord.meeting(in: ["com.google.Chrome", "us.zoom.xos"], playing: []) == .app)
    #expect(MeetingAutoRecord.meeting(in: ["dev.alex.blurt", "com.apple.VoiceMemos"], playing: []) == nil)
    #expect(MeetingAutoRecord.meeting(in: [], playing: []) == nil)
  }

  @Test("a browser holding the mic but playing nothing isn't a call (#345)")
  func browserMicAloneDoesNotCount() {
    // Voice search, a getUserMedia test page, a site's mic prompt: input only.
    #expect(MeetingAutoRecord.meeting(in: ["com.google.Chrome"], playing: []) == nil)
    // Another app (or another browser) playing doesn't make it two-way.
    #expect(MeetingAutoRecord.meeting(in: ["com.google.Chrome"], playing: ["com.apple.Safari"]) == nil)
    #expect(MeetingAutoRecord.meeting(in: ["com.apple.Safari"], playing: ["com.apple.Music"]) == nil)
  }

  @Test("the switch is off unless set")
  func storeDefaultsOff() throws {
    let defaults = try #require(UserDefaults(suiteName: "MeetingAutoRecordTests-\(UUID())"))
    #expect(!MeetingAutoRecordStore(defaults: defaults).isEnabled)
    defaults.set(true, forKey: MeetingAutoRecordStore.defaultsKey)
    #expect(MeetingAutoRecordStore(defaults: defaults).isEnabled)
  }
}
