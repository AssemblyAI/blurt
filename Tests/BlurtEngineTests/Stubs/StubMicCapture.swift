import Foundation

@testable import BlurtEngine

actor StubMicCapture: MicCaptureProtocol {
  var startCalls = 0
  var stopCalls = 0
  var cancelCaptureCalls = 0
  /// The canned audio the feed publishes — and, by its length, what `stop()`
  /// reports. One value for both so a test setting it moves the request's
  /// payload and the release path's length check together, as production does.
  var pcmToReturn = StubPCM.aboveMinimum
  var startError: (any Error & Sendable)?
  var stopError: (any Error & Sendable)?

  private var framesContinuation: AsyncStream<Data>.Continuation?

  // Actor-isolated methods satisfy these `async` protocol requirements directly,
  // so no `nonisolated` + hop-back-onto-self dance is needed.
  func start() throws -> AsyncStream<Data> {
    startCalls += 1
    if let startError { throw startError }
    // Publishes the "captured" bytes while recording is open and ends only at
    // `stop()` / `cancelCapture()`, modelled on the real recorder. A stub that
    // handed back an already-finished feed let the request complete during the
    // press, so the ordering the config-part-last framing depends on — frames
    // first, context resolved after — was never exercised by a session test.
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    framesContinuation = continuation
    if !pcmToReturn.isEmpty { continuation.yield(pcmToReturn) }
    return stream
  }
  func stop() throws -> Int {
    stopCalls += 1
    // Ends the feed before the (possibly throwing) stop, mirroring
    // `CaptureSessionRecorder.stopAndReadByteCount`: the upload's body is completed by
    // the recording stopping, not by the stop succeeding.
    finishFrames()
    if let stopError { throw stopError }
    return pcmToReturn.count
  }

  private func finishFrames() {
    framesContinuation?.finish()
    framesContinuation = nil
  }
  /// Counts the call, then delegates to `stop()` so `stopCalls` and `stopError`
  /// mean "the mic was stopped" however the teardown was reached — the suites
  /// that assert a cancel stopped the mic (and that a failing stop is logged)
  /// read them.
  func cancelCapture() throws {
    cancelCaptureCalls += 1
    _ = try stop()
  }
  /// No meter: the session suites never read one.
  nonisolated var levels: AsyncStream<Float> { .finished }
  func warmUp() {
    // Nothing to pre-pay: the stub opens no device.
  }
  func setPCM(_ pcm: Data) { pcmToReturn = pcm }
  func setStartError(_ error: (any Error & Sendable)?) { startError = error }
  func setStopError(_ error: (any Error & Sendable)?) { stopError = error }
}
