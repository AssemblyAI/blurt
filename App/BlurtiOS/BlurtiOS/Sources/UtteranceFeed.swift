import BlurtEngine
import Foundation
import Synchronization

/// The per-utterance feed both microphones push into: the engine gets one
/// stream per press, the meter a level per chunk, and the byte tally is what
/// `stop()` reports so the engine can drop a press too short to transcribe.
///
/// It also keeps the silence watchdog: a run of `silenceSeconds` of digital
/// silence inside an open utterance is reported once, through `onSilence`,
/// because a live route never delivers a second of exact zeros. A route
/// coming up may, held or parked — so every start holds the watchdog until
/// the first chunk with sound in it, and a route change holds it again
/// (`holdSilence`). A microphone that delivers only zeros is still said,
/// after `startGraceSeconds` of them: a dead mic is said, not recorded.
nonisolated final class UtteranceFeed: Sendable {
  private struct State {
    var sink: AsyncStream<Data>.Continuation?
    var bytes = 0
    /// Digital silence since the last live chunk, in bytes.
    var silentBytes = 0
    /// A chunk with sound in it has arrived since the start or the last route
    /// change: the watchdog counts to `silenceBytes`; before it, to the grace.
    var heardSound = false
    /// Said once per run of silence.
    var silenceReported = false
  }

  /// How much digital silence an open utterance tolerates, once it has heard
  /// a live chunk, before the watchdog says the microphone hears nothing
  /// (DESIGN.md).
  static let silenceSeconds = 1
  /// How long a start — or a route change — may deliver nothing but zeros
  /// before the watchdog says so anyway: the parked bring-up's own first-frame
  /// budget (`WindowedAudioSource.firstFrameTimeout`).
  static let startGraceSeconds = 3
  /// That second as 16 kHz mono 16-bit PCM.
  static let silenceBytes = silenceSeconds * SyncSTTLimits.sampleRate * MemoryLayout<Int16>.size
  static let startGraceBytes = startGraceSeconds * SyncSTTLimits.sampleRate * MemoryLayout<Int16>.size

  private let state = Mutex(State())
  private let levelsContinuation: AsyncStream<Float>.Continuation
  private let onSilence: @Sendable () -> Void
  let levels: AsyncStream<Float>

  /// Whether an utterance is open. A microphone checks this before converting
  /// a buffer that `deliver` would only drop.
  var isCapturing: Bool { state.withLock { $0.sink != nil } }

  /// How much the open utterance has carried so far, silence included.
  var bytesSoFar: Int { state.withLock { $0.bytes } }

  init(
    onSilence: @escaping @Sendable () -> Void = {
      // No one to tell: a feed built without a listener keeps its silence to itself.
    }
  ) {
    let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
    levels = stream
    levelsContinuation = continuation
    self.onSilence = onSilence
  }

  /// Counts the chunk toward the watchdog; true the once a run of silence
  /// reaches the limit — a second once sound has been heard, the start's
  /// grace before.
  private static func watch(_ state: inout State, _ chunk: Data) -> Bool {
    guard isDigitalSilence(chunk) else {
      state.heardSound = true
      state.silentBytes = 0
      state.silenceReported = false
      return false
    }
    state.silentBytes += chunk.count
    let limit = state.heardSound ? silenceBytes : startGraceBytes
    guard state.silentBytes >= limit, !state.silenceReported else {
      return false
    }
    state.silenceReported = true
    return true
  }

  /// Every sample exactly zero: what a microphone route delivers while it is
  /// still coming up, never what a live one hears in a quiet room.
  static func isDigitalSilence(_ pcm: Data) -> Bool {
    pcm.allSatisfy { $0 == 0 }
  }

  /// Starts an utterance: chunks delivered from now on go to the returned
  /// stream. Any utterance still open is finished first. The watchdog waits
  /// for the first chunk with sound in it.
  func begin() -> AsyncStream<Data> {
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    state.withLock { state in
      state.sink?.finish()
      state.sink = continuation
      state.bytes = 0
      state.silentBytes = 0
      state.heardSound = false
      state.silenceReported = false
    }
    return stream
  }

  /// The route changed under the utterance: the new one may deliver zeros
  /// while it comes up, so the watchdog waits for its first live chunk again.
  func holdSilence() {
    state.withLock { state in
      state.silentBytes = 0
      state.heardSound = false
      state.silenceReported = false
    }
  }

  /// Ends the utterance and reports how many bytes it carried.
  @discardableResult
  func end() -> Int {
    state.withLock { state in
      let bytes = state.bytes
      state.sink?.finish()
      state.sink = nil
      state.bytes = 0
      state.silentBytes = 0
      state.silenceReported = false
      return bytes
    }
  }

  /// A chunk of 16 kHz mono 16-bit PCM from the microphone, on whatever
  /// thread the microphone delivers on.
  func deliver(_ chunk: Data) {
    guard !chunk.isEmpty else {
      return
    }
    // Nothing to report between utterances: a window sits open for minutes,
    // and a level a dozen times a second would only keep views redrawing.
    let (delivered, silent) = state.withLock { state -> (Bool, Bool) in
      guard let sink = state.sink else {
        return (false, false)
      }
      state.bytes += chunk.count
      sink.yield(chunk)
      return (true, Self.watch(&state, chunk))
    }
    if delivered { levelsContinuation.yield(PCMLevel.level(of: chunk)) }
    if silent { onSilence() }
  }
}
