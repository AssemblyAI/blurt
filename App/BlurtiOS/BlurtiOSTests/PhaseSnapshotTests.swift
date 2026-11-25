import Foundation
import Testing

@testable import BlurtiOSCore

@Suite("Phase snapshot staleness")
struct PhaseSnapshotTests {
  private func snapshot(_ state: PhaseSnapshot.State, ageSeconds: TimeInterval) -> PhaseSnapshot {
    PhaseSnapshot(state: state, message: nil, level: 0, at: Date().addingTimeInterval(-ageSeconds))
  }

  @Test("idle is never stale")
  func idle() {
    #expect(!snapshot(.idle, ageSeconds: 100_000).isStale)
  }

  @Test("a notice is over after three seconds")
  func notices() {
    for state in [PhaseSnapshot.State.pasted, .copied, .error] {
      #expect(!snapshot(state, ageSeconds: 2).isStale)
      #expect(snapshot(state, ageSeconds: 4).isStale)
    }
  }

  @Test("an in-flight state outlives no dictation past 1210 seconds")
  func inFlight() {
    for state in [PhaseSnapshot.State.connecting, .recording, .processing] {
      #expect(!snapshot(state, ageSeconds: 1_200).isStale)
      #expect(snapshot(state, ageSeconds: 1_211).isStale)
    }
  }

  @Test("the dwell matches the design: 1.2 s pasted, 2 s copied and error, none otherwise")
  func dwell() {
    #expect(snapshot(.pasted, ageSeconds: 0).noticeDwellSeconds == 1.2)
    #expect(snapshot(.copied, ageSeconds: 0).noticeDwellSeconds == 2)
    #expect(snapshot(.error, ageSeconds: 0).noticeDwellSeconds == 2)
    #expect(snapshot(.recording, ageSeconds: 0).noticeDwellSeconds == nil)
  }
}
