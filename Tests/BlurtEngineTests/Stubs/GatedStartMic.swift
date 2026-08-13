import Foundation

@testable import BlurtEngine

/// Mic stub whose `start()` signals entry and then blocks until the test
/// releases it — standing in for the real capture's liveness wait — so commands
/// (a release, a cancel) can be landed deterministically while the press is
/// suspended in `mic.start()` and the session sits in `.connecting`. The
/// entry/finish choreography lives in the shared `Gate`, mirroring
/// `GatedStopMic`.
actor GatedStartMic: MicCaptureProtocol {
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  private let gate = Gate()

  func start() async throws {
    startCalls += 1
    await gate.enter()
  }

  func stop() async throws -> Data {
    stopCalls += 1
    // These suites exercise the connecting window, not the too-short-audio guard.
    return StubPCM.aboveMinimum
  }

  func waitUntilStartEntered() async { await gate.waitUntilEntered() }
  func allowStartToFinish() async { gate.allowToFinish() }
}
