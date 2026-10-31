import BlurtEngine

// "Auto-record meetings": while the switch is on, a probe every few seconds
// asks Core Audio whether a meeting app (or a browser) holds the microphone,
// and `MeetingAutoRecord` turns that into starting and
// stopping a recording. Split from TranscriptsModel.swift for its length.
extension TranscriptsModel {
  /// Starts or stops watching for meetings, as the switch is set.
  func setAutoRecordMeetings(_ isOn: Bool) {
    meetingProbe?.cancel()
    meetingProbe = nil
    meetingPolicy = MeetingAutoRecord()
    guard isOn else { return }
    meetingProbe = Task { [weak self] in
      while !Task.isCancelled {
        await self?.probeForMeeting()
        try? await Task.sleep(for: MeetingAutoRecord.probeInterval)
      }
    }
  }

  /// The user stopped or discarded a recording: an auto-started one isn't
  /// stopped again, and none restarts until a meeting that's on ends.
  func noteUserStoppedRecording() {
    meetingPolicy.userStopped(meetingActive: lastMeetingActive)
  }

  private func probeForMeeting() async {
    // Synchronous Core Audio reads: off the main actor.
    let active = await Task.detached(priority: .utility) { MeetingMicProbe.meetingInProgress() }.value
    guard !Task.isCancelled else { return }
    lastMeetingActive = active
    switch meetingPolicy.probe(meetingActive: active, recording: isRecording, now: .now) {
    case .start:
      // Not over a sheet already in use (a transcript open, a file going up):
      // treat it as a decline, so this meeting doesn't keep asking.
      if canRecord { startRecording() }
      if !isRecording { meetingPolicy.userStopped(meetingActive: true) }
    case .stop:
      stopRecording(byUser: false)
    case .none:
      break
    }
  }
}
