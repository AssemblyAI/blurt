import Foundation

public protocol MicCaptureProtocol: Sendable {
  /// Begin capturing 16 kHz mono 16-bit PCM. Throws on permission/device failure.
  ///
  /// **May hold until the input device actually delivers frames.** A Bluetooth
  /// route spends up to ~2.5 s switching into its mic-capable profile before any
  /// audio flows, and the OS captures nothing in that window. Hosts render the
  /// whole in-flight call as a distinct "connecting" state (the pipeline's
  /// `.connecting` phase), with the "speak now" cues — the recording pill, the
  /// start chime — arriving only on return. A conformer that returns before
  /// frames flow cues the user to speak into a dead mic, and the first words of
  /// the utterance are unrecoverable.
  ///
  /// Returns the live PCM feed for the capture it just started: raw S16LE
  /// chunks in arrival order, ending when the capture stops. This is what makes
  /// the upload chunked — the dictation request opens at press and drains this
  /// while the user speaks, so ending the feed is what tells the service the
  /// utterance is over.
  ///
  /// Handed back by `start()` rather than fetched separately so the ordering
  /// cannot be got wrong: a feed always belongs to a capture that is running,
  /// and there is no window in which to ask for one before (or after) there is
  /// anything behind it. Asking separately raced the release — the capture could
  /// already have been torn down, and the answer was an empty feed that uploaded
  /// an utterance with no audio in it.
  func start() async throws -> AsyncStream<Data>
  /// Stop capture and return how many bytes of audio it produced.
  ///
  /// A count, not the audio: the recording is uploaded on the feed `start()`
  /// returned, as it is captured, so by the time capture stops there is nothing
  /// left to hand anyone. All the release path still needs is whether there was
  /// enough of it to be worth transcribing (`SyncSTTLimits.minPCMBytes`).
  /// Returning the blob as well meant copying every byte a second time and
  /// holding a duplicate of the whole utterance until release.
  ///
  /// `throws` so a conformer whose teardown can genuinely fail surfaces it
  /// instead of silently reporting a clean stop; `MicCapture` never does.
  func stop() async throws -> Int
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
  /// Optionally pay whatever set-up cost the first `start()` would otherwise
  /// pay on the hot path. Must **not** open the input device — no capture, no
  /// mic indicator, nothing held between presses — and must not throw; a failure
  /// just means `start()` pays it. `MicCapture` documents what is and isn't
  /// pre-payable here, which is less than it looks. Declared here (not only in
  /// the default extension) so it dispatches dynamically through
  /// `any MicCaptureProtocol`.
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
