import AVFoundation
import BlurtEngine
import CoreMedia
import Foundation

/// The microphone behind an iOS dictation: an audio-only capture session that
/// stays open for the whole listening window and hands each utterance its own
/// feed.
///
/// This is deliberately not the Mac's fresh-session-per-press `MicCapture`.
/// iOS refuses to open the microphone from the background, and during a
/// dictation the app *is* in the background — the user is in the app they are
/// typing in, with the Blurt keyboard up. So the app opens the microphone once,
/// while it is in front (the `blurt://start` hop the keyboard makes), keeps it
/// open for the window, and a press simply starts forwarding the frames that
/// are already flowing. What that buys beyond legality is the fastest start
/// the engine has ever had: no device open, no liveness wait, `.recording`
/// within a frame of the press. What it costs is the orange microphone
/// indicator for the length of the window, which is the trade every iPhone
/// dictation keyboard makes.
///
/// The output's native format is converted to the 16 kHz mono 16-bit the
/// dictation API wants by `PCMConverter` (`audioSettings`, which does that on
/// the Mac, is not in the iOS SDK). `@unchecked Sendable` by confinement, the
/// same way the Mac recorder is: the feed and its tally live behind `UtteranceFeed`'s lock,
/// the converter is touched only on the serial delivery queue, and the session
/// is configured once and then only started and stopped.
nonisolated final class WindowedAudioSource: NSObject, ListeningSource, @unchecked Sendable {
  enum Failure: Error, LocalizedError {
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

  private let feed = UtteranceFeed()
  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  /// Serial, so the converter below needs no lock.
  private let deliveryQueue = DispatchQueue(label: "dev.alex.blurt.ios.capture")
  private nonisolated(unsafe) var converter: PCMConverter?

  var levels: AsyncStream<Float> { feed.levels }

  override init() {
    super.init()
    output.setSampleBufferDelegate(self, queue: deliveryQueue)
  }

  /// Running and not taken away: iOS keeps a session "running" through an
  /// interruption (a phone call, Siri), while no frames arrive.
  var isOpen: Bool { session.isRunning && !session.isInterrupted }

  /// Opens the microphone. Only works from the foreground; the audio session
  /// must already be active (`ListeningWindow` does both, in that order).
  func open() throws {
    guard !session.isRunning else { return }
    session.beginConfiguration()
    session.automaticallyConfiguresApplicationAudioSession = false
    if session.inputs.isEmpty {
      guard let device = AVCaptureDevice.default(for: .audio) else {
        session.commitConfiguration()
        throw Failure.noInputDevice
      }
      let input = try AVCaptureDeviceInput(device: device)
      if session.canAddInput(input) { session.addInput(input) }
    }
    if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
    session.commitConfiguration()
    session.startRunning()
    guard session.isRunning else { throw Failure.noInputDevice }
  }

  /// Releases the microphone and ends any utterance in flight.
  func close() {
    if session.isRunning { session.stopRunning() }
    feed.end()
  }

  // MARK: MicCaptureProtocol

  func start() throws -> AsyncStream<Data> {
    guard session.isRunning else {
      throw BlurtError.audioCaptureFailed(underlying: Failure.windowClosed)
    }
    return feed.begin()
  }

  func stop() -> Int { feed.end() }

  func cancelCapture() { feed.end() }
}

// The conformance is spelled `nonisolated`: with the target defaulting to the
// main actor, an extension's conformance is inferred main-actor even on a
// `nonisolated` class, and the output calls it on the delivery queue.
extension WindowedAudioSource: nonisolated AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    if converter == nil { converter = PCMConverter() }
    guard let converter, let chunk = converter.convert(sampleBuffer) else { return }
    feed.deliver(chunk)
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
