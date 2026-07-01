public protocol MicCaptureProtocol: Sendable {
  /// Begin capturing mono Float32 samples at 16 kHz. Throws on permission/device failure.
  func start() async throws
  /// Stop capture and return all captured samples in order. Throws if the
  /// captured audio couldn't be processed (e.g. sample-rate conversion failed),
  /// so the pipeline can surface an error instead of silently dropping speech.
  func stop() async throws -> [Float]
}
