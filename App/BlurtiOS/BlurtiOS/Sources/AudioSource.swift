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
/// `park()` is the way out of that cost. Once a silent loop keeps the app
/// running (`AudioKeepAlive`; `MicParking` has the rule), the window parks the source: the
/// session stops whenever no utterance is open, a press starts it again and
/// waits for its first frame — the engine shows `.connecting` meanwhile — and
/// the indicator is on only while the user dictates. A press that can't bring
/// the microphone back is reported on `failedStarts`, so the window can stop
/// parking.
///
/// The output's native format is converted to the 16 kHz mono 16-bit the
/// dictation API wants by `PCMConverter` (`audioSettings`, which does that on
/// the Mac, is not in the iOS SDK). `@unchecked Sendable` by confinement, the
/// same way the Mac recorder is: the feed and its tally live behind
/// `UtteranceFeed`'s lock, the converter is touched only on the serial delivery
/// queue, the session is configured, started and stopped only on the serial
/// control queue, and the flags read across them are atomics.
nonisolated final class WindowedAudioSource: NSObject, ListeningSource, @unchecked Sendable {
  /// How long a press waits for a parked microphone's first frame. A Bluetooth
  /// route spends up to ~2.5 s switching into its mic-capable profile.
  private static let firstFrameTimeout: Duration = .seconds(3)

  private let feed = UtteranceFeed()
  private let session = AVCaptureSession()
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
  private let failures: AsyncStream<Void>.Continuation
  let failedStarts: AsyncStream<Void>

  var levels: AsyncStream<Float> { feed.levels }

  override init() {
    (failedStarts, failures) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    super.init()
    output.setSampleBufferDelegate(self, queue: deliveryQueue)
  }

  /// Open and not taken away: iOS keeps a session "running" through an
  /// interruption (a phone call, Siri), while no frames arrive. A parked
  /// session isn't running between utterances and is still open.
  var isOpen: Bool {
    opened.load(ordering: .acquiring) && !session.isInterrupted
      && (session.isRunning || parking.load(ordering: .acquiring))
  }

  /// Opens the microphone and holds it open. Only works from the foreground;
  /// the audio session must already be active (`ListeningWindow` does both,
  /// in that order).
  func open() async throws {
    parking.store(false, ordering: .releasing)
    try await onControlQueue {
      try self.runOnControlQueue()
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
      try self.runOnControlQueue()
    }
  }

  private func runOnControlQueue() throws {
    // A session left "running" through an interruption resumes on its own
    // terms; stopping it first makes the reopen deterministic.
    if session.isRunning, session.isInterrupted { session.stopRunning() }
    guard !session.isRunning else { return }
    try configure()
    session.startRunning()
    guard session.isRunning, !session.isInterrupted else { throw ListeningSourceFailure.noInputDevice }
  }

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
    // no microphone, said where the user can see it.
    if session.inputs.isEmpty {
      guard let device = AVCaptureDevice.default(for: .audio) else { throw ListeningSourceFailure.noInputDevice }
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else { throw ListeningSourceFailure.noInputDevice }
      session.addInput(input)
    }
    if session.outputs.isEmpty {
      guard session.canAddOutput(output) else { throw ListeningSourceFailure.noInputDevice }
      session.addOutput(output)
    }
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
      // which the engine's timing contract forbids.
      guard session.isRunning, !session.isInterrupted else {
        throw BlurtError.audioCaptureFailed(underlying: ListeningSourceFailure.windowClosed)
      }
      return feed.begin()
    }
    return try await startParked()
  }

  /// Starts a parked session for one utterance and holds until its first
  /// frame, so the "speak now" cues never arrive over a microphone still
  /// coming up.
  /// A cancel during the bring-up (the keyboard's ×, or the window closing)
  /// ends the wait at once rather than when the mic comes up.
  private func startParked() async throws -> AsyncStream<Data> {
    firstFrame.arm()
    let stream = feed.begin()
    let firstFrame = firstFrame
    let started: Bool
    do {
      started = try await withTaskCancellationHandler {
        try await onControlQueue { () throws -> Bool in
          // Closed meanwhile: starting now would leave a mic running with no window.
          guard self.opened.load(ordering: .acquiring) else { return false }
          try self.runOnControlQueue()
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
    guard arrived else { try failStart(ListeningSourceFailure.noInputDevice) }
    return stream
  }

  /// Undoes a parked start. A cancel or a closed window is the user's (or the
  /// window's) doing: the session hears `CancellationError`, its cancel
  /// path, and nothing is reported as the phone refusing the mic.
  private func failStart(_ error: any Error) throws -> Never {
    firstFrame.cancel()
    feed.end()
    controlQueue.async { self.parkOnControlQueue() }
    if Task.isCancelled || !opened.load(ordering: .acquiring) { throw CancellationError() }
    failures.yield()
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

/// Converts whatever format the microphone delivers into the dictation API's
/// 16 kHz mono 16-bit little-endian PCM. One instance per delivery queue; it
/// rebuilds its converter if the input format changes underneath it (a route
/// change to AirPods, say).
nonisolated final class PCMConverter {
  /// One buffer per `convert` call: the first pull gets it, every later pull
  /// is told there is no more for now. The converter's input block is
  /// `@Sendable` and escaping in type but runs synchronously on this thread
  /// before `convert` returns, so an unchecked box is sound — and unlike a
  /// `Mutex`, it can be captured.
  private final class Handoff: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
      defer { buffer = nil }
      return buffer
    }
  }

  private let outputFormat: AVAudioFormat
  private var inputFormat: AVAudioFormat?
  private var converter: AVAudioConverter?

  init?() {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(SyncSTTLimits.sampleRate), channels: 1,
        interleaved: true)
    else { return nil }
    outputFormat = format
  }

  func convert(_ sampleBuffer: CMSampleBuffer) -> Data? {
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
    else { return nil }
    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard frames > 0, let input = inputBuffer(matching: streamDescription, frames: frames) else { return nil }
    input.frameLength = frames
    let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
    guard copied == noErr, let converter, let inputFormat else { return nil }
    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      return nil
    }
    let handoff = Handoff(input)
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
      guard let buffer = handoff.take() else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, conversionError == nil, outputBuffer.frameLength > 0,
      let channels = outputBuffer.int16ChannelData
    else { return nil }
    return Data(bytes: channels[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
  }

  /// A buffer in the input's own format, rebuilding the converter when the
  /// format is new or changed.
  private func inputBuffer(
    matching streamDescription: UnsafePointer<AudioStreamBasicDescription>, frames: AVAudioFrameCount
  ) -> AVAudioPCMBuffer? {
    if inputFormat == nil || !Self.matches(inputFormat, streamDescription.pointee) {
      guard let format = AVAudioFormat(streamDescription: streamDescription) else { return nil }
      inputFormat = format
      converter = AVAudioConverter(from: format, to: outputFormat)
    }
    guard let inputFormat else { return nil }
    return AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)
  }

  private static func matches(_ format: AVAudioFormat?, _ description: AudioStreamBasicDescription) -> Bool {
    guard let format else { return false }
    let current = format.streamDescription.pointee
    return current.mSampleRate == description.mSampleRate
      && current.mChannelsPerFrame == description.mChannelsPerFrame
      && current.mFormatID == description.mFormatID
      && current.mFormatFlags == description.mFormatFlags
      && current.mBitsPerChannel == description.mBitsPerChannel
  }
}
