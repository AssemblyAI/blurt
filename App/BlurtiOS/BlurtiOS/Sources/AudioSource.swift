import AVFoundation
import BlurtEngine
import CoreMedia
import Foundation
import Synchronization

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
/// same way the Mac recorder is: the feed and its tally live behind a `Mutex`,
/// the converter is touched only on the serial delivery queue, and the session
/// is configured once and then only started and stopped.
nonisolated final class WindowedAudioSource: NSObject, MicCaptureProtocol, @unchecked Sendable {
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

  private struct Feed {
    var sink: AsyncStream<Data>.Continuation?
    var bytes = 0
  }

  private let feed = Mutex(Feed())
  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  /// Serial, so the converter below needs no lock.
  private let deliveryQueue = DispatchQueue(label: "dev.alex.blurt.ios.capture")
  private nonisolated(unsafe) var converter: PCMConverter?
  private let levelsContinuation: AsyncStream<Float>.Continuation
  /// The 0…1 meter the keyboard pill renders, at the output's own cadence.
  let levels: AsyncStream<Float>

  override init() {
    let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
    levels = stream
    levelsContinuation = continuation
    super.init()
    output.setSampleBufferDelegate(self, queue: deliveryQueue)
  }

  var isOpen: Bool { session.isRunning }

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
    _ = endUtterance()
  }

  // MARK: MicCaptureProtocol

  func start() throws -> AsyncStream<Data> {
    guard session.isRunning else {
      throw BlurtError.audioCaptureFailed(underlying: Failure.windowClosed)
    }
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    feed.withLock { feed in
      feed.sink?.finish()
      feed.sink = continuation
      feed.bytes = 0
    }
    return stream
  }

  func stop() -> Int { endUtterance() }

  func cancelCapture() { _ = endUtterance() }

  private func endUtterance() -> Int {
    feed.withLock { feed in
      let bytes = feed.bytes
      feed.sink?.finish()
      feed.sink = nil
      feed.bytes = 0
      return bytes
    }
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

extension WindowedAudioSource: AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    if converter == nil { converter = PCMConverter() }
    guard let converter, let chunk = converter.convert(sampleBuffer), !chunk.isEmpty else { return }
    levelsContinuation.yield(Self.level(of: chunk))
    feed.withLock { feed in
      guard let sink = feed.sink else { return }
      feed.bytes += chunk.count
      sink.yield(chunk)
    }
  }
}

/// Converts whatever format the microphone delivers into the dictation API's
/// 16 kHz mono 16-bit little-endian PCM. One instance per delivery queue; it
/// rebuilds its converter if the input format changes underneath it (a route
/// change to AirPods, say).
nonisolated final class PCMConverter {
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
    var handedOver = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
      if handedOver {
        inputStatus.pointee = .noDataNow
        return nil
      }
      handedOver = true
      inputStatus.pointee = .haveData
      return input
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
