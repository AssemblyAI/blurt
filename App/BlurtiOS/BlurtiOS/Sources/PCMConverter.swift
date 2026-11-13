import AVFoundation
import BlurtEngine
import CoreMedia
import Foundation

/// Converts whatever format the microphone delivers into the dictation API's
/// 16 kHz mono 16-bit little-endian PCM. One instance per delivery queue; it
/// rebuilds its converter if the input format changes underneath it (a route
/// change to AirPods, say). `WindowedAudioSource`'s; its own file so the
/// source's stays within the lint budget.
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
