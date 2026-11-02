import BlurtEngine

// Recording with meetings: a probe every few seconds asks Core Audio whether
// a meeting app (or a browser) holds the microphone, and `MeetingAutoRecord`
// turns that into starting and stopping a recording. It probes while the
// "Auto-record meetings" switch is on, and during any recording — so one
// started by hand in a meeting ends with it, switch or no switch. Split from
// TranscriptsModel.swift for its length.
extension TranscriptsModel {
  /// Sets the switch, and starts the probe loop the first time.
  func setAutoRecordMeetings(_ isOn: Bool) {
    autoRecordMeetings = isOn
    guard meetingProbe == nil else { return }
    meetingProbe = Task { [weak self] in
      while !Task.isCancelled {
        await self?.probeForMeeting()
        try? await Task.sleep(for: MeetingAutoRecord.probeInterval)
      }
    }
  }

  /// The user started a recording: if a meeting is on, it ends with it.
  func noteUserStartedRecording() {
    meetingPolicy.userStarted()
  }

  /// The user stopped or discarded a recording: an auto-started one isn't
  /// stopped again, and none restarts until a meeting that's on ends.
  func noteUserStoppedRecording() {
    meetingPolicy.userStopped(meetingActive: lastMeetingActive)
  }

  private func probeForMeeting() async {
    // Nothing to start or stop: leave Core Audio alone.
    guard autoRecordMeetings || isRecording else { return }
    // Synchronous Core Audio reads: off the main actor.
    let meeting = await Task.detached(priority: .utility) { MeetingMicProbe.meetingInProgress() }.value
    guard !Task.isCancelled else { return }
    lastMeetingActive = meeting != nil
    let action = meetingPolicy.probe(
      meeting: meeting, recording: isRecording, autoStart: autoRecordMeetings, now: .now)
    switch action {
    case .start:
      // Not over a sheet already in use (a transcript open, a file going up):
      // treat it as a decline, so this meeting doesn't keep asking.
      if canRecord { startRecording(byUser: false) }
      if !isRecording { meetingPolicy.userStopped(meetingActive: true) }
    case .stop:
      stopRecording(byUser: false)
    case .none:
      break
    }
  }
}
