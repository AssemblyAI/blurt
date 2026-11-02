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
    #expect(policy.probe(meetingActive: false, recording: false, now: at(0)) == .none)
    #expect(policy.probe(meetingActive: true, recording: false, now: at(5)) == .start)
  }

  @Test("stops only after the meeting has been gone for a minute straight; a return resets it")
  func hysteresis() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meetingActive: true, recording: false, now: at(0)) == .start)
    #expect(policy.probe(meetingActive: false, recording: true, now: at(10)) == .none)
    #expect(policy.probe(meetingActive: true, recording: true, now: at(30)) == .none)
    #expect(policy.probe(meetingActive: false, recording: true, now: at(40)) == .none)
    #expect(policy.probe(meetingActive: false, recording: true, now: at(99)) == .none)
    #expect(policy.probe(meetingActive: false, recording: true, now: at(100)) == .stop)
  }

  @Test("never stops a recording the user started")
  func leavesManualRecordings() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meetingActive: false, recording: true, now: at(0)) == .none)
    #expect(policy.probe(meetingActive: false, recording: true, now: at(120)) == .none)
  }

  @Test("a user stop mid-meeting holds off until that meeting ends")
  func userStopSuppresses() {
    var policy = MeetingAutoRecord()
    #expect(policy.probe(meetingActive: true, recording: false, now: at(0)) == .start)
    policy.userStopped(meetingActive: true)
    #expect(policy.probe(meetingActive: true, recording: false, now: at(5)) == .none)
    #expect(policy.probe(meetingActive: false, recording: false, now: at(10)) == .none)
    #expect(policy.probe(meetingActive: true, recording: false, now: at(15)) == .start)
  }

  @Test("meeting apps and browsers count; other mic users and Blurt don't")
  func whatCounts() {
    #expect(MeetingAutoRecord.indicatesMeeting(["us.zoom.xos"]))
    #expect(MeetingAutoRecord.indicatesMeeting(["us.zoom.CptHost"]))
    #expect(MeetingAutoRecord.indicatesMeeting(["com.microsoft.teams2", "com.apple.Music"]))
    #expect(MeetingAutoRecord.indicatesMeeting(["com.google.Chrome"]))
    #expect(!MeetingAutoRecord.indicatesMeeting(["dev.alex.blurt", "com.apple.VoiceMemos"]))
    #expect(!MeetingAutoRecord.indicatesMeeting([]))
  }

  @Test("the switch is off unless set")
  func storeDefaultsOff() throws {
    let defaults = try #require(UserDefaults(suiteName: "MeetingAutoRecordTests-\(UUID())"))
    #expect(!MeetingAutoRecordStore(defaults: defaults).isEnabled)
    defaults.set(true, forKey: MeetingAutoRecordStore.defaultsKey)
    #expect(MeetingAutoRecordStore(defaults: defaults).isEnabled)
  }
}
