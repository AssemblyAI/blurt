import BlurtEngine
import Foundation
import Synchronization

/// What the listening window needs from a microphone: opened once for the
/// window, closed with it, and feeding the engine per utterance in between.
/// `WindowedAudioSource` is the phone's; `SimulatorAudioSource` stands in
/// where the simulator has no capture session.
nonisolated protocol ListeningSource: MicCaptureProtocol {
  var isOpen: Bool { get }
  /// The 0…1 meter the orb and the home screen render, one value per chunk
  /// of an open utterance.
  var levels: AsyncStream<Float> { get }
  /// Opens the microphone. Async because opening a capture session blocks for
  /// hundreds of milliseconds on a phone and must not do so on the main actor.
  func open() async throws
  func close() async
}

/// Why a microphone couldn't open or start.
nonisolated enum ListeningSourceFailure: Error, LocalizedError {
  /// A press arrived with no listening window open — the keyboard's job is to
  /// open the app first, so this is a plumbing fault, not a user error.
  case windowClosed
  case noInputDevice

  var errorDescription: String? {
    switch self {
    case .windowClosed: "Blurt isn't listening. Open Blurt to start."
    case .noInputDevice: "No microphone is available."
    }
  }
}

/// The per-utterance feed both microphones push into: the engine gets one
/// stream per press, the meter a level per chunk, and the byte tally is what
/// `stop()` reports so the engine can drop a press too short to transcribe.
nonisolated final class UtteranceFeed: Sendable {
  private struct State {
    var sink: AsyncStream<Data>.Continuation?
    var bytes = 0
  }

  private let state = Mutex(State())
  private let levelsContinuation: AsyncStream<Float>.Continuation
  let levels: AsyncStream<Float>

  init() {
    let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
    levels = stream
    levelsContinuation = continuation
  }

  /// Starts an utterance: chunks delivered from now on go to the returned
  /// stream. Any utterance still open is finished first.
  func begin() -> AsyncStream<Data> {
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    state.withLock { state in
      state.sink?.finish()
      state.sink = continuation
      state.bytes = 0
    }
    return stream
  }

  /// Ends the utterance and reports how many bytes it carried.
  @discardableResult
  func end() -> Int {
    state.withLock { state in
      let bytes = state.bytes
      state.sink?.finish()
      state.sink = nil
      state.bytes = 0
      return bytes
    }
  }

  /// A chunk of 16 kHz mono 16-bit PCM from the microphone, on whatever
  /// thread the microphone delivers on.
  func deliver(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    // Nothing to report between utterances: a window sits open for minutes,
    // and a level a dozen times a second would only keep views redrawing.
    let delivered = state.withLock { state -> Bool in
      guard let sink = state.sink else { return false }
      state.bytes += chunk.count
      sink.yield(chunk)
      return true
    }
    if delivered { levelsContinuation.yield(Self.level(of: chunk)) }
  }

  /// dBFS of a chunk of 16-bit PCM, mapped to 0…1 with the Mac meter's -50 dB
  /// floor so room ambient reads as empty bars.
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
    guard rms > 0 else { return 0 }
    let floor = -50.0
    let db = 20 * log10(rms)
    guard db > floor else { return 0 }
    return Float(min(1, (db - floor) / -floor))
  }
}
