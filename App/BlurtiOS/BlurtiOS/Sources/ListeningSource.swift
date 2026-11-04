import BlurtEngine
import Foundation
import Synchronization

/// What the listening window needs from a microphone: opened once for the
/// window, closed with it, and feeding the engine per utterance in between —
/// held open the whole time, or, once parked, open only while an utterance
/// is. `WindowedAudioSource` is the phone's; `SimulatorAudioSource` stands in
/// where the simulator has no capture session.
nonisolated protocol ListeningSource: MicCaptureProtocol {
  var isOpen: Bool { get }
  /// The 0…1 meter the orb and the home screen render, one value per chunk
  /// of an open utterance.
  var levels: AsyncStream<Float> { get }
  /// What the microphone reports about itself while the window is open —
  /// taken away and given back, dying, its route changing, an utterance that
  /// hears nothing — in the order it happened. One reader: the window.
  var events: AsyncStream<SourceEvent> { get }
  /// One element each time a parked source couldn't bring the microphone
  /// back for a press — iOS refusing a start from the background, as far as
  /// the window can tell (`MicParking`).
  var failedStarts: AsyncStream<Void> { get }
  /// Opens the microphone and holds it open. Async because opening a capture
  /// session blocks for hundreds of milliseconds on a phone and must not do
  /// so on the main actor.
  func open() async throws
  /// From now until `close`, releases the microphone between utterances and
  /// reopens it on each press.
  func park() async
  /// Back to holding the microphone open between utterances. Foreground only.
  func hold() async throws
  func close() async
}

/// Something the microphone said about itself, after the fact. A failure is
/// what a start throws; an event is what happens to a microphone already open.
nonisolated enum SourceEvent: Sendable, Equatable {
  /// iOS took the input — a call, Siri, another app recording. `reason` is
  /// the system's name for why (`audioDeviceInUseByAnotherClient`, …).
  case interrupted(reason: String)
  case interruptionEnded
  /// The capture session failed while running; `code` is the system's.
  case runtimeError(code: Int)
  /// The audio route changed under the microphone: `input` names the port
  /// now feeding it (`BluetoothHFP`, `MicrophoneBuiltIn`), nil when none does.
  case routeChanged(reason: String, input: String?)
  /// The silence watchdog: an open utterance heard `UtteranceFeed.silenceSeconds`
  /// of digital silence, which no live route delivers.
  case silent
}

/// Why a microphone couldn't open or start. Each case is its own sentence,
/// for the home screen; `CaptureFailure` turns each into the keyboard's
/// `FailureReason`.
nonisolated enum ListeningSourceFailure: Error, LocalizedError, Equatable {
  /// A press arrived with no listening window open — the keyboard's job is to
  /// open the app first, so this is a plumbing fault, not a user error.
  case windowClosed
  /// The phone has no audio input at all.
  case noInputDevice
  /// iOS has the input: a call, Siri, another app recording. `reason` is the
  /// system's name for why.
  case interrupted(reason: String)
  /// The capture session died while running; `code` is the system's.
  case runtimeError(code: Int)
  /// The session refused its input or output; `code` is the system's, 0 when
  /// it gave none.
  case configureFailed(code: Int)
  /// The microphone came up and delivered only digital silence.
  case inputSilent
  /// An interruption ended and the session didn't come back.
  case couldNotResume
  /// A parked start from the background that iOS refused: the session was
  /// left not running with no interruption to blame, and `code` is the error
  /// it posted, 0 when it posted none. The remedy is the foreground.
  case backgroundStartRefused(code: Int)

  var errorDescription: String? {
    switch self {
    case .windowClosed: "The session is off."
    case .noInputDevice: "No microphone is available."
    case .interrupted: "A call or another app has the microphone."
    case .runtimeError: "The microphone stopped unexpectedly."
    case .configureFailed: "The microphone couldn't be set up."
    case .inputSilent: "The microphone isn't sending any audio."
    case .couldNotResume: "The microphone didn't come back after the interruption."
    case .backgroundStartRefused: "Open Blurt to start the microphone."
    }
  }
}

/// The per-utterance feed both microphones push into: the engine gets one
/// stream per press, the meter a level per chunk, and the byte tally is what
/// `stop()` reports so the engine can drop a press too short to transcribe.
///
/// It also keeps the silence watchdog: a run of `silenceSeconds` of digital
/// silence inside an open utterance is reported once, through `onSilence`,
/// because a live route never delivers a second of exact zeros. A parked
/// route may, while it comes up — `begin(watchingSilence: false)` holds the
/// count until `watchSilence()` says the first live frame has arrived.
nonisolated final class UtteranceFeed: Sendable {
  /// How much digital silence an open utterance tolerates before the
  /// watchdog says the microphone hears nothing (DESIGN.md).
  static let silenceSeconds = 1
  /// That second as 16 kHz mono 16-bit PCM.
  static let silenceBytes = silenceSeconds * SyncSTTLimits.sampleRate * MemoryLayout<Int16>.size

  private struct State {
    var sink: AsyncStream<Data>.Continuation?
    var bytes = 0
    /// Digital silence since the last live chunk, in bytes.
    var silentBytes = 0
    var watchingSilence = true
    /// Said once per run of silence.
    var silenceReported = false
  }

  private let state = Mutex(State())
  private let levelsContinuation: AsyncStream<Float>.Continuation
  private let onSilence: @Sendable () -> Void
  let levels: AsyncStream<Float>

  init(onSilence: @escaping @Sendable () -> Void = {}) {
    let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
    levels = stream
    levelsContinuation = continuation
    self.onSilence = onSilence
  }

  /// Starts an utterance: chunks delivered from now on go to the returned
  /// stream. Any utterance still open is finished first. `watchingSilence`
  /// false holds the watchdog until `watchSilence()`.
  func begin(watchingSilence: Bool = true) -> AsyncStream<Data> {
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    state.withLock { state in
      state.sink?.finish()
      state.sink = continuation
      state.bytes = 0
      state.silentBytes = 0
      state.silenceReported = false
      state.watchingSilence = watchingSilence
    }
    return stream
  }

  /// Turns the watchdog on for the open utterance: the route has delivered
  /// its first live frame, so a second of zeros from now on means it died.
  func watchSilence() {
    state.withLock { $0.watchingSilence = true }
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

  /// Whether an utterance is open. A microphone checks this before converting
  /// a buffer that `deliver` would only drop.
  var isCapturing: Bool { state.withLock { $0.sink != nil } }

  /// How much the open utterance has carried so far, silence included.
  var bytesSoFar: Int { state.withLock { $0.bytes } }

  /// A chunk of 16 kHz mono 16-bit PCM from the microphone, on whatever
  /// thread the microphone delivers on.
  func deliver(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    // Nothing to report between utterances: a window sits open for minutes,
    // and a level a dozen times a second would only keep views redrawing.
    let (delivered, silent) = state.withLock { state -> (Bool, Bool) in
      guard let sink = state.sink else { return (false, false) }
      state.bytes += chunk.count
      sink.yield(chunk)
      return (true, Self.watch(&state, chunk))
    }
    if delivered { levelsContinuation.yield(Self.level(of: chunk)) }
    if silent { onSilence() }
  }

  /// Counts the chunk toward the watchdog; true the once a run of silence
  /// reaches `silenceBytes`.
  private static func watch(_ state: inout State, _ chunk: Data) -> Bool {
    guard state.watchingSilence else { return false }
    guard isDigitalSilence(chunk) else {
      state.silentBytes = 0
      state.silenceReported = false
      return false
    }
    state.silentBytes += chunk.count
    guard state.silentBytes >= silenceBytes, !state.silenceReported else { return false }
    state.silenceReported = true
    return true
  }

  /// Every sample exactly zero: what a microphone route delivers while it is
  /// still coming up, never what a live one hears in a quiet room.
  static func isDigitalSilence(_ pcm: Data) -> Bool {
    pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).allSatisfy { $0 == 0 } }
  }

  /// dBFS of a chunk of 16-bit PCM, mapped to 0…1 by the Mac meter's own
  /// mapping, so room ambient reads as empty bars on both.
  static func level(of pcm: Data) -> Float {
    let count = pcm.count / MemoryLayout<Int16>.size
    guard count > 0 else { return 0 }
    let energy = pcm.withUnsafeBytes { raw -> Double in
      raw.bindMemory(to: Int16.self).reduce(0) { sum, sample in
        let value = Double(sample)
        return sum + value * value
      }
    }
    let rms = (energy / Double(count)).squareRoot() / Double(Int16.max)
    return MicCapture.linearLevel(fromPowerDB: Float(20 * log10(rms)))
  }
}
