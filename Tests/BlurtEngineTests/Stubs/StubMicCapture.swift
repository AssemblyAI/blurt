import Foundation

@testable import BlurtEngine

actor StubMicCapture: MicCaptureProtocol {
  var startCalls = 0
  var stopCalls = 0
  var cancelCaptureCalls = 0
  var pcmToReturn = StubPCM.aboveMinimum
  var startError: (any Error & Sendable)?
  var stopError: (any Error & Sendable)?

  // Actor-isolated methods satisfy these `async` protocol requirements directly,
  // so no `nonisolated` + hop-back-onto-self dance is needed.
  func start() async throws {
    startCalls += 1
    if let startError { throw startError }
  }
  func stop() async throws -> Data {
    stopCalls += 1
    // Ends the feed before the (possibly throwing) stop, mirroring
    // `CaptureSessionRecorder.stopAndReadPCM`: the upload's body is completed by
    // the recording stopping, not by the stop succeeding.
    finishFrames()
    if let stopError { throw stopError }
    return pcmToReturn
  }

  /// The live feed the chunked upload drains, modelled on the real recorder
  /// rather than shortcut to a finished stream: the "captured" bytes are
  /// published while recording is open, and the feed ends only at `stop()` /
  /// `cancelCapture()`.
  ///
  /// That fidelity is the point. A stub that handed back an
  /// already-finished stream let the request complete during the press, so the
  /// ordering the config-part-last framing depends on — frames first, context
  /// resolved after — was never exercised by any session test.
  func frames() async -> AsyncStream<Data> {
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    framesContinuation = continuation
    if !pcmToReturn.isEmpty { continuation.yield(pcmToReturn) }
    return stream
  }

  private var framesContinuation: AsyncStream<Data>.Continuation?

  private func finishFrames() {
    framesContinuation?.finish()
    framesContinuation = nil
  }
  /// Overrides the protocol's stop-and-discard default only to *count* the call,
  /// then delegates to `stop()` so `stopCalls` and `stopError` keep meaning what
  /// they did before the cancel path had its own entry point — the suites that
  /// assert a cancel stopped the mic (and that a failing stop is logged) are
  /// unchanged. `MicCaptureProtocolDefaultsTests` covers the bare default.
  func cancelCapture() async throws {
    cancelCaptureCalls += 1
    _ = try await stop()
  }
  func setPCM(_ pcm: Data) { pcmToReturn = pcm }
  func setStartError(_ error: (any Error & Sendable)?) { startError = error }
  func setStopError(_ error: (any Error & Sendable)?) { stopError = error }
}
