import Foundation

public protocol MicCaptureProtocol: Sendable {
  /// Begin capturing 16 kHz mono 16-bit PCM. Throws on permission/device failure.
  func start() async throws
  /// Stop capture and return the captured audio as raw S16LE PCM bytes — the
  /// exact encoding the dictation request uploads, so no conversion pass sits on
  /// the release hot path. Throws if the captured audio couldn't be read back,
  /// so the pipeline can surface an error instead of silently dropping speech.
  func stop() async throws -> Data
  /// Stop capture and discard the audio — the teardown behind a *cancel*, where
  /// the user asked for nothing to happen. Split from `stop()` because the two
  /// want opposite things: `stop()` may legitimately spend time preserving the
  /// captured audio (`MicCapture` waits out a Bluetooth link's tail before
  /// ending the recording), whereas a cancel must take effect immediately and
  /// has nothing to preserve. Declared here (not only in the default extension)
  /// so it dispatches dynamically through `any MicCaptureProtocol`.
  func cancelCapture() async throws
  /// Loudness feed for a meter UI: `0…1`, emitted while recording. Declared on
  /// the protocol (with an empty-stream default below) so hosts read the meter
  /// through the same seam they inject — a stub without a meter satisfies it
  /// for free instead of every composition threading a side-channel stream.
  var levels: AsyncStream<Float> { get }
  /// Optionally pre-open the capture device so the first `start()` doesn't pay
  /// hardware route discovery on the hot path. Must not begin capture (no mic
  /// indicator) and must not throw — a failure just means `start()` prepares
  /// lazily as before. Declared here (not only in the default extension) so it
  /// dispatches dynamically through `any MicCaptureProtocol`.
  func warmUp() async
}

extension MicCaptureProtocol {
  /// No-meter default: an immediately finished stream, so captures without a
  /// meter (test stubs, headless hosts) conform without supplying one.
  public var levels: AsyncStream<Float> { AsyncStream { $0.finish() } }

  /// No-op default: a capture with nothing to pre-open inherits this, mirroring
  /// `TranscriberProtocol.warmUp`.
  public func warmUp() async {}

  /// Stop-and-discard default, so a capture with no cancel-specific teardown
  /// (every stub) conforms for free and still records the stop the way it always
  /// did. Implementations override it when stopping cheaply differs from
  /// stopping carefully — `MicCapture` does.
  public func cancelCapture() async throws {
    _ = try await stop()
  }
}
