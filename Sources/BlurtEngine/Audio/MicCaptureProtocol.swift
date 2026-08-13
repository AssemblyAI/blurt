import Foundation

public protocol MicCaptureProtocol: Sendable {
  /// Begin capturing 16 kHz mono 16-bit PCM. Throws on permission/device failure.
  /// May hold until the input device actually delivers frames — a Bluetooth
  /// route spends up to ~2.5 s switching profiles (A2DP→HFP) before any audio
  /// flows — and hosts render the whole in-flight call as a distinct
  /// "connecting" state (the pipeline's `.connecting` phase), with the
  /// "speak now" cues arriving only on return. A conformer that returns
  /// before frames flow cues the user to speak into a dead mic.
  func start() async throws
  /// Stop capture and return the captured audio as raw S16LE PCM bytes — the
  /// exact encoding the dictation request uploads, so no conversion pass sits on
  /// the release hot path. Throws if the captured audio couldn't be read back,
  /// so the pipeline can surface an error instead of silently dropping speech.
  func stop() async throws -> Data
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
}
