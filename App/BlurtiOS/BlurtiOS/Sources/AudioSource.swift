import AVFoundation
import BlurtEngine
import CoreMedia
import Foundation
import Synchronization

/// The microphone behind an iOS dictation: an audio-only capture session that
/// opens with the listening window and hands each utterance its own feed.
///
/// This is deliberately not the Mac's fresh-session-per-press `MicCapture`.
/// iOS refuses to open the microphone from the background, and during a
/// dictation the app *is* in the background — the user is in the app they are
/// typing in, with the Blurt keyboard up. So the app opens the microphone once,
/// while it is in front (the `blurt://start` hop the keyboard makes), and holds
/// it open, and a press simply starts forwarding the frames that are already
/// flowing: no device open, no liveness wait, `.recording` within a frame of
/// the press. What holding costs is the orange microphone indicator for the
/// length of the window.
///
/// `park()` is the way out of that cost. Once a Picture in Picture keeper
/// holds the process's foreground role (`PictureInPictureIdle`), the window
/// parks the source: the session stops whenever no utterance is open, a press
/// starts it again and waits for its first frame — the engine shows
/// `.connecting` meanwhile — and the indicator is on only while the user
/// dictates. A press that can't bring the microphone back throws
/// `backgroundStartRefused`, typed, and the window hears of it through the
/// coordinator's capture failure.
///
/// What the session says about itself — an interruption, a runtime error, the
/// route changing — reaches the window as `events` and the log as one line
/// each (`WindowedAudioSource+Events.swift`), and a start that finds the
/// session down throws the typed `ListeningSourceFailure` those notifications
/// explain, never "No microphone is available." for a refusal.
///
/// The output's native format is converted to the 16 kHz mono 16-bit the
/// dictation API wants by `PCMConverter` (`audioSettings`, which does that on
/// the Mac, is not in the iOS SDK). `@unchecked Sendable` by confinement, the
/// same way the Mac recorder is: the feed and its tally live behind
/// `UtteranceFeed`'s lock, the converter is touched only on the serial delivery
/// queue, the session is configured, started and stopped only on the serial
/// control queue (where its observers are registered, too), the notification
/// handlers touch only the sink, the mutexes and the session's flags, and the
/// flags read across them are atomics.
nonisolated final class WindowedAudioSource: NSObject, ListeningSource, @unchecked Sendable {
  /// How long a press waits for a parked microphone's first frame. A Bluetooth
  /// route spends up to ~2.5 s switching into its mic-capable profile.
  private static let firstFrameTimeout: Duration = .seconds(3)
  static let log = HostIdentity.current.logger("Capture")

  let feed: UtteranceFeed
  let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  /// Serial, so the converter below needs no lock.
  private let deliveryQueue = DispatchQueue(label: "com.assemblyai.blurt.ios.capture")
  /// Where the session is started and stopped — both block for a while on a
  /// phone — so the main actor never waits on the capture stack.
  private let controlQueue = DispatchQueue(label: "com.assemblyai.blurt.ios.capture.control")
  private nonisolated(unsafe) var converter: PCMConverter?
  /// Opened for a window and not closed since — still true while parked.
  private let opened = Atomic<Bool>(false)
  /// Parked: the session runs only while an utterance is open.
  private let parking = Atomic<Bool>(false)
  private let firstFrame = FirstFrame()
  let eventSink: AsyncStream<SourceEvent>.Continuation
  let events: AsyncStream<SourceEvent>
  /// The session's observers, registered once on the control queue
  /// (`observeSession`) and removed with the source.
  nonisolated(unsafe) var observers: [any NSObjectProtocol] = []
  /// The code of the runtime error the session posted since its last start,
  /// which is what a start that finds it down reports.
  let lastRuntimeError = Mutex<Int?>(nil)
  /// The reason for the interruption still on, if one is.
  let interruption = Mutex<String?>(nil)
  /// An interruption ended with the held session still down: the next start
  /// is a resume, and its failure is `couldNotResume`.
  let downAfterInterruption = Atomic<Bool>(false)

  var levels: AsyncStream<Float> { feed.levels }

  override init() {
    let (events, sink) = AsyncStream<SourceEvent>.makeStream()
    self.events = events
    eventSink = sink
    feed = UtteranceFeed(onSilence: { sink.yield(.silent) })
    super.init()
    output.setSampleBufferDelegate(self, queue: deliveryQueue)
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// Open and not taken away: iOS keeps a session "running" through an
  /// interruption (a phone call, Siri), while no frames arrive. A parked
  /// session isn't running between utterances and is still open.
  var isOpen: Bool {
    opened.load(ordering: .acquiring) && !session.isInterrupted
      && (session.isRunning || parking.load(ordering: .acquiring))
  }

  /// Opened and holding: the session is meant to be running right now.
  var isHeldOpen: Bool { opened.load(ordering: .acquiring) && !parking.load(ordering: .acquiring) }

  /// The session's two flags, for every log line.
  var sessionFlags: String { "running=\(session.isRunning) interrupted=\(session.isInterrupted)" }

  /// Opens the microphone and holds it open. Only works from the foreground;
  /// the audio session must already be active (`ListeningWindow` does both,
  /// in that order).
  func open() async throws {
    parking.store(false, ordering: .releasing)
    try await onControlQueue {
      try self.runOnControlQueue(parked: false)
      // Set on the queue the parks run on, so a park still queued from the
      // last window can't stop this one's session.
      self.opened.store(true, ordering: .releasing)
    }
  }

  /// From now until `close`, releases the microphone whenever no utterance is
  /// open — including right now, if none is.
  func park() async {
    parking.store(true, ordering: .releasing)
    await onControlQueue { self.parkOnControlQueue() }
  }

  /// Back to holding the microphone open between utterances, starting it if
  /// it is parked. Foreground only, like `open`.
  func hold() async throws {
    parking.store(false, ordering: .releasing)
    try await onControlQueue {
      guard self.opened.load(ordering: .acquiring) else { return }
      try self.runOnControlQueue(parked: false)
    }
  }

  /// Starts the session if it isn't running, observers first. Throws the
  /// typed failure for a session the start left down.
  private func runOnControlQueue(parked: Bool) throws {
    // A session left "running" through an interruption resumes on its own
    // terms; stopping it first makes the reopen deterministic.
    if session.isRunning, session.isInterrupted { session.stopRunning() }
    guard !session.isRunning else { return }
    observeSession()
    try configure()
    lastRuntimeError.withLock { $0 = nil }
    session.startRunning()
    Self.log.notice("capture start parked=\(parked) \(self.sessionFlags, privacy: .public)")
    guard session.isRunning, !session.isInterrupted else { throw startFailure(parked: parked) }
    // A start that took is the end of whatever interruption came before it.
    interruption.withLock { $0 = nil }
    downAfterInterruption.store(false, ordering: .releasing)
  }

  /// Why a start left the session down: taken away; dead, with the code it
  /// posted; not back from an interruption; or — parked, so from the
  /// background — refused by iOS with no word why.
  private func startFailure(parked: Bool) -> ListeningSourceFailure {
    if session.isInterrupted { return .interrupted(reason: interruptionReason) }
    let code = lastRuntimeError.withLock { $0 }
    if parked { return .backgroundStartRefused(code: code ?? 0) }
    if let code { return .runtimeError(code: code) }
    return downAfterInterruption.load(ordering: .acquiring) ? .couldNotResume : .runtimeError(code: 0)
  }

  /// The interruption's reason as the session gave it, or "unknown" when its
  /// notification hasn't landed yet.
  var interruptionReason: String { interruption.withLock { $0 } ?? Self.unknownReason }

  /// Stops a parked session between utterances — or any idle session once
  /// the window has closed, which is how a start that raced `close` still
  /// ends with the mic off. Checked on the control queue, where starts run
  /// too, so a press that came in meanwhile keeps its mic.
  private func parkOnControlQueue() {
    let releases = parking.load(ordering: .acquiring) || !opened.load(ordering: .acquiring)
    guard releases, !feed.isCapturing, session.isRunning else { return }
    session.stopRunning()
  }

  /// Adds the input and output once. `commitConfiguration` runs on every
  /// path out, including a throw, so a failed attempt never leaves the
  /// session mid-configuration for the next one.
  private func configure() throws {
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.automaticallyConfiguresApplicationAudioSession = false
    // A session refused its input or output would still start running — and
    // hear nothing, which is worse than failing: the window would open, the
    // keyboard would record, and the upload would get no frames. Refused is
    // a failure with the system's code, said where the user can see it.
    if session.inputs.isEmpty {
      guard let device = AVCaptureDevice.default(for: .audio) else { throw ListeningSourceFailure.noInputDevice }
      let input: AVCaptureDeviceInput
      do {
        input = try AVCaptureDeviceInput(device: device)
      } catch {
        throw configureFailed(code: (error as NSError).code)
      }
      guard session.canAddInput(input) else { throw configureFailed(code: 0) }
      session.addInput(input)
    }
    if session.outputs.isEmpty {
      guard session.canAddOutput(output) else { throw configureFailed(code: 0) }
      session.addOutput(output)
    }
  }

  private func configureFailed(code: Int) -> ListeningSourceFailure {
    Self.log.error("capture configure failed code=\(code)")
    return .configureFailed(code: code)
  }

  /// Releases the microphone and ends any utterance in flight.
  func close() async {
    opened.store(false, ordering: .releasing)
    parking.store(false, ordering: .releasing)
    await onControlQueue {
      if self.session.isRunning { self.session.stopRunning() }
      self.feed.end()
    }
    firstFrame.cancel()
    // The window is over, and so is any interruption it was waiting out: the
    // next window's first start must not report a call that ended with this one.
    interruption.withLock { $0 = nil }
  }

  private func onControlQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
      controlQueue.async { continuation.resume(with: Result { try work() }) }
    }
  }

  private func onControlQueue(_ work: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      controlQueue.async {
        work()
        continuation.resume()
      }
    }
  }

  // MARK: MicCaptureProtocol

  func start() async throws -> AsyncStream<Data> {
    guard opened.load(ordering: .acquiring) else {
      throw BlurtError.audioCaptureFailed(underlying: ListeningSourceFailure.windowClosed)
    }
    guard parking.load(ordering: .acquiring) else {
      // Held open: an interrupted session is "running" and delivering
      // nothing, and a feed from it would claim `.recording` over a dead mic,
      // which the engine's timing contract forbids. The watchdog waits for
      // the first live chunk (`UtteranceFeed`): a held route can deliver
      // zeros too, right after a route change.
      guard session.isRunning, !session.isInterrupted else {
        throw BlurtError.audioCaptureFailed(underlying: heldSessionDown())
      }
      return feed.begin()
    }
    return try await startParked()
  }

  /// Why a held session isn't there for a press: taken away, dead, not back
  /// from an interruption — or, with nothing reported, never started.
  private func heldSessionDown() -> ListeningSourceFailure {
    if session.isInterrupted { return .interrupted(reason: interruptionReason) }
    if let code = lastRuntimeError.withLock({ $0 }) { return .runtimeError(code: code) }
    return downAfterInterruption.load(ordering: .acquiring) ? .couldNotResume : .windowClosed
  }

  /// Starts a parked session for one utterance and holds until its first
  /// frame, so the "speak now" cues never arrive over a microphone still
  /// coming up.
  /// A cancel during the bring-up (the keyboard's ×, or the window closing)
  /// ends the wait at once rather than when the mic comes up.
  private func startParked() async throws -> AsyncStream<Data> {
    firstFrame.arm()
    // A route coming up delivers zeros; the first-frame timeout judges those,
    // and the feed's watchdog waits for the first live chunk by itself.
    let stream = feed.begin()
    let firstFrame = firstFrame
    let started: Bool
    do {
      started = try await withTaskCancellationHandler {
        try await onControlQueue { () throws -> Bool in
          // Closed meanwhile: starting now would leave a mic running with no window.
          guard self.opened.load(ordering: .acquiring) else { return false }
          try self.runOnControlQueue(parked: true)
          return true
        }
      } onCancel: {
        firstFrame.cancel()
      }
    } catch {
      try failStart(error)
    }
    let arrived =
      started
      ? await withTaskCancellationHandler {
        await firstFrame.wait(timeout: Self.firstFrameTimeout)
      } onCancel: {
        firstFrame.cancel()
      } : false
    guard arrived else { try failStart(noFirstFrame()) }
    return stream
  }

  /// Why a started session gave no live frame in time: taken away
  /// meanwhile; frames that were all zeros; or none at all, which from the
  /// background is iOS declining to say no.
  private func noFirstFrame() -> ListeningSourceFailure {
    if session.isInterrupted { return .interrupted(reason: interruptionReason) }
    if feed.bytesSoFar > 0 { return .inputSilent }
    return .backgroundStartRefused(code: lastRuntimeError.withLock { $0 } ?? 0)
  }

  /// Undoes a parked start. A cancel or a closed window is the user's (or the
  /// window's) doing: the session hears `CancellationError`, its cancel
  /// path, and nothing is reported as the phone refusing the mic. Anything
  /// else is thrown typed, for the coordinator to hand the window as a reason.
  private func failStart(_ error: any Error) throws -> Never {
    firstFrame.cancel()
    feed.end()
    controlQueue.async { self.parkOnControlQueue() }
    if Task.isCancelled || !opened.load(ordering: .acquiring) { throw CancellationError() }
    Self.log.error("capture parked start failed: \(error.localizedDescription, privacy: .public)")
    throw BlurtError.audioCaptureFailed(underlying: error)
  }

  func stop() -> Int {
    let bytes = feed.end()
    parkWhenIdle()
    return bytes
  }

  func cancelCapture() {
    feed.end()
    parkWhenIdle()
  }

  private func parkWhenIdle() {
    guard parking.load(ordering: .acquiring) else { return }
    controlQueue.async { self.parkOnControlQueue() }
  }
}

// The conformance is spelled `nonisolated`: with the target defaulting to the
// main actor, an extension's conformance is inferred main-actor even on a
// `nonisolated` class, and the output calls it on the delivery queue.
extension WindowedAudioSource: nonisolated AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    // A held window keeps the mic open for minutes between utterances;
    // resampling buffers nobody will read is wasted. The converter is dropped
    // with them, so the next utterance doesn't start on the old audio's
    // resampler tail.
    guard feed.isCapturing else {
      converter = nil
      return
    }
    if converter == nil { converter = PCMConverter() }
    guard let converter, let chunk = converter.convert(sampleBuffer) else { return }
    feed.deliver(chunk)
    // A route coming up can deliver zeros before it hears anything; only a
    // frame with sound in it proves the mic is live.
    if !UtteranceFeed.isDigitalSilence(chunk) { firstFrame.arrived() }
  }
}
