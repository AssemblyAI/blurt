import Testing

@testable import BlurtEngine

/// The shared recording-edge detector behind both the record chimes
/// (`RecordingCueGate`) and the music pause/resume. The host feeds it *every*
/// phase, so the contract that matters is silence everywhere except the two real
/// transitions — a spurious `.ended` resumes music mid-sentence, and a missed one
/// leaves it paused for good.
@Suite("RecordingEdgeDetector")
struct RecordingEdgeDetectorTests {
  @Test("reports began on entering recording and ended on leaving it")
  func reportsBothEdges() {
    var detector = RecordingEdgeDetector()
    #expect(detector.edge(for: .idle) == nil)
    #expect(detector.edge(for: .recording) == .began)
    #expect(detector.edge(for: .transcribing) == .ended)
  }

  @Test("a repeated phase doesn't re-fire an edge")
  func repeatedPhaseIsSilent() {
    var detector = RecordingEdgeDetector()
    #expect(detector.edge(for: .recording) == .began)
    #expect(detector.edge(for: .recording) == nil)
    #expect(detector.edge(for: .recording) == nil)
  }

  @Test("transitions between two non-recording phases stay silent")
  func nonRecordingTransitionsAreSilent() {
    // The tail of a normal dictation: everything after the mic closes must not
    // touch the music again.
    var detector = RecordingEdgeDetector()
    #expect(detector.edge(for: .recording) == .began)
    #expect(detector.edge(for: .transcribing) == .ended)
    #expect(detector.edge(for: .injecting) == nil)
    #expect(detector.edge(for: .pasted) == nil)
    #expect(detector.edge(for: .idle) == nil)
  }

  @Test("ended fires when the mic closes, not when the dictation finishes")
  func endedFiresAtMicClose() {
    // Deliberate: the resume rides this edge so the music comes back as the
    // recording stops, not a second later when the paste lands.
    var detector = RecordingEdgeDetector()
    _ = detector.edge(for: .recording)
    #expect(detector.edge(for: .transcribing) == .ended)
  }

  @Test("a cancelled dictation still reports ended")
  func cancelStillEnds() {
    // A cancel goes .recording → .cancelled with no transcribe step. If this
    // didn't report `.ended`, cancelling would leave the music paused forever.
    var detector = RecordingEdgeDetector()
    #expect(detector.edge(for: .recording) == .began)
    #expect(detector.edge(for: .cancelled) == .ended)
  }

  @Test("a failed press never opened the mic, so there is no edge to report")
  func refusedPressReportsNothing() {
    // A press refused for a missing API key goes straight to .failed without ever
    // recording — pausing the music for it would be a pure annoyance.
    var detector = RecordingEdgeDetector()
    #expect(detector.edge(for: .failed(.apiKeyMissing)) == nil)
  }

  @Test("the connecting phase doesn't fire an edge — .began waits for audio to flow")
  func connectingIsNotAnEdge() {
    // A press first claims `.connecting` while MicCapture's liveness gate waits for
    // the input route to deliver frames (on Bluetooth, ~1-2 s). The edge must ride
    // connecting→recording, not the press: pausing music or chiming at the press
    // would fire while nothing is being captured yet, and on the pause side would
    // mean resuming before the user has finished speaking.
    var detector = RecordingEdgeDetector()
    #expect(detector.edge(for: .connecting) == nil)
    #expect(detector.edge(for: .recording) == .began)
    #expect(detector.edge(for: .transcribing) == .ended)
  }

  @Test("a connect that never reaches recording reports no edges at all")
  func abandonedConnectIsSilent() {
    // The mic never opened, so there is nothing to have suppressed and nothing to
    // restore — a spurious `.ended` here would resume music that was never paused.
    var detector = RecordingEdgeDetector()
    #expect(detector.edge(for: .connecting) == nil)
    #expect(detector.edge(for: .failed(.apiKeyMissing)) == nil)
    #expect(detector.edge(for: .idle) == nil)
  }

  @Test("back-to-back dictations each get their own pair of edges")
  func consecutiveDictations() {
    var detector = RecordingEdgeDetector()
    for _ in 0..<3 {
      #expect(detector.edge(for: .recording) == .began)
      #expect(detector.edge(for: .transcribing) == .ended)
      #expect(detector.edge(for: .idle) == nil)
    }
  }
}
