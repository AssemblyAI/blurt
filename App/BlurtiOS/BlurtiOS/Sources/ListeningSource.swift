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
  /// hears nothing — in the order it happened. One reader: the window. A
  /// press's start that fails is not an event: it throws its typed failure
  /// to the engine, and the coordinator hands the window the reason.
  var events: AsyncStream<SourceEvent> { get }
  /// Opens the microphone and holds it open. Async because opening a capture
  /// session blocks for hundreds of milliseconds on a phone and must not do
  /// so on the main actor.
  func open() async throws
  /// From now until `close` or `hold`, releases the microphone between
  /// utterances and reopens it on each press (`PictureInPictureIdle`).
  func park() async
  /// Back to holding the microphone open between utterances. Foreground only.
  func hold() async throws
  func close() async
}
