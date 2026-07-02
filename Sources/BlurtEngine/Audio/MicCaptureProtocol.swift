public protocol MicCaptureProtocol: Sendable {
  /// Begin capturing mono Float32 samples at 16 kHz. Throws on permission/device failure.
  func start() async throws
  /// Stop capture and return all captured samples in order. Throws if the
  /// captured audio couldn't be processed (e.g. sample-rate conversion failed),
  /// so the pipeline can surface an error instead of silently dropping speech.
  func stop() async throws -> [Float]
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
