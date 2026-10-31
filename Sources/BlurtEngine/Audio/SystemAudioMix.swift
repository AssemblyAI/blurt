#if os(macOS)
  import AVFoundation
  import AssemblyAI
  import CoreAudio
  import Foundation

  // `SystemAudioRecorder`'s mixing and writing, apart from its Core Audio
  // setup: everything here runs on plain buffers, so it is unit-tested and
  // counted by the coverage gate, while the recorder itself — a process tap
  // and an aggregate device — needs real hardware and is excluded with the
  // other HAL files (scripts/check.sh).

  /// The IOProc's half: mixes each cycle to mono, converts it to 16 kHz, appends
  /// it to the file and hands it to `onPCM`. Every buffer is allocated once, in
  /// `init`, so a cycle allocates nothing but the PCM bytes it hands on.
  /// `@unchecked Sendable` because it is touched only on the recorder's serial
  /// queue — the IOProc's, and `teardown`'s `close` — never concurrently.
  final class MixWriter: @unchecked Sendable {
    private var file: AVAudioFile?
    private let converter: AVAudioConverter
    private let mixBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let mixSamples: UnsafeMutablePointer<Float>
    private let outputSamples: UnsafeMutablePointer<Int16>
    private let onPCM: @Sendable (Data) -> Void
    /// The converter's input, built once: hands it the armed buffer, then
    /// "no more for now".
    private let cycle = OneShot()
    private let inputBlock: AVAudioConverterInputBlock
    /// 16-bit PCM not yet handed on, up to `handOffBytes`.
    private var pending = Data()
    /// 100 ms of 16 kHz 16-bit mono: what `onPCM` is handed at a time.
    static let handOffBytes = RealtimeTranscriber.chunkBytes
    /// What reached the writer, for the stop log line: a recording that comes
    /// back empty is told apart from one that never got a callback.
    private var callbacks = 0
    private var framesIn = 0
    private var framesOut = 0
    private var lastError: String?

    var summary: String {
      "\(callbacks) callbacks, \(framesIn) frames in, \(framesOut) out\(lastError.map { ", last error: \($0)" } ?? "")"
    }

    init(url: URL, inputRate: Double, maxFrames: Int, onPCM: @escaping @Sendable (Data) -> Void) throws {
      // Room for the largest cycle the device delivers, twice over: a larger
      // one would be truncated to this (`mix`), so the margin is generous.
      let capacity = AVAudioFrameCount(max(maxFrames, 512) * 2)
      let outputRate = SystemAudioRecorder.outputSampleRate
      guard let mixFormat = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1),
        // 16-bit, as the realtime API takes it: the converter resamples and
        // quantizes in one pass, so no float-to-Int16 loop of our own.
        let outputFormat = AVAudioFormat(
          commonFormat: .pcmFormatInt16, sampleRate: outputRate, channels: 1, interleaved: true),
        let converter = AVAudioConverter(from: mixFormat, to: outputFormat),
        let mixBuffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: capacity),
        let outputBuffer = AVAudioPCMBuffer(
          pcmFormat: outputFormat,
          frameCapacity: AVAudioFrameCount((Double(capacity) * outputRate / inputRate).rounded(.up)) + 64),
        let mixSamples = mixBuffer.floatChannelData?[0],
        let outputSamples = outputBuffer.int16ChannelData?[0]
      else {
        throw SystemAudioRecorder.RecorderError.coreAudio("format", kAudioFormatUnsupportedDataFormatError)
      }
      self.converter = converter
      self.mixBuffer = mixBuffer
      self.outputBuffer = outputBuffer
      self.mixSamples = mixSamples
      self.outputSamples = outputSamples
      self.onPCM = onPCM
      inputBlock = { [cycle] _, status in
        guard let buffer = cycle.take() else {
          status.pointee = .noDataNow
          return nil
        }
        status.pointee = .haveData
        return buffer
      }
      // Written at the output rate, so the file's processing format *is* the
      // converter's output — no second rate for the two to disagree on.
      file = try AVAudioFile(
        forWriting: url,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: outputRate,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 32_000,
        ],
        commonFormat: .pcmFormatInt16, interleaved: true)
    }

    func write(_ input: UnsafePointer<AudioBufferList>) {
      guard file != nil else { return }
      let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
      let frames = Self.mix(buffers, into: mixSamples, capacity: Int(mixBuffer.frameCapacity))
      callbacks += 1
      framesIn += frames
      if callbacks == 1 {
        let shape = buffers.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ", ")
        SystemAudioRecorder.log.info(
          "recorder first callback: \(buffers.count, privacy: .public) buffers [\(shape, privacy: .public)]")
      }
      guard frames > 0 else { return }
      mixBuffer.frameLength = AVAudioFrameCount(frames)
      outputBuffer.frameLength = 0
      var error: NSError?
      // One cycle's worth, then "no more for now" — never end-of-stream, so
      // the resampler carries its state into the next cycle. The block is built
      // once; each cycle only re-arms it.
      cycle.arm(mixBuffer)
      converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
      let count = Int(outputBuffer.frameLength)
      if let error { lastError = error.localizedDescription }
      guard error == nil, count > 0 else { return }
      framesOut += count
      try? file?.write(from: outputBuffer)
      // Handed on 100 ms at a time — the realtime API's message size — rather
      // than a ~10 ms slice per cycle, so the hop to the socket happens a tenth
      // as often.
      pending.append(UnsafeBufferPointer(start: outputSamples, count: count))
      if pending.count >= Self.handOffBytes {
        onPCM(pending)
        pending.removeAll(keepingCapacity: true)
      }
    }

    /// Flushes what's left to `onPCM` and closes the file.
    func close() {
      if !pending.isEmpty { onPCM(pending) }
      pending.removeAll()
      file = nil
    }

    /// Hands the converter its one buffer per cycle. The input block is typed
    /// `@Sendable` but runs synchronously inside `convert`, on this queue —
    /// hence unchecked.
    private final class OneShot: @unchecked Sendable {
      private var buffer: AVAudioPCMBuffer?
      func arm(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
      func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
      }
    }

    /// Each buffer (one stream: the mic, the tap) averaged across its own
    /// interleaved channels, then the streams summed and clamped to [-1, 1],
    /// into `out`. Float32 samples, as the HAL delivers to an IOProc. Returns
    /// the frame count, at most `capacity`.
    static func mix(
      _ buffers: UnsafeMutableAudioBufferListPointer, into out: UnsafeMutablePointer<Float>, capacity: Int
    ) -> Int {
      var frames = 0
      for buffer in buffers {
        let channels = Int(max(buffer.mNumberChannels, 1))
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let count = min(Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels), capacity)
        if count > frames {
          (out + frames).initialize(repeating: 0, count: count - frames)
          frames = count
        }
        for frame in 0..<count {
          var sum: Float = 0
          for channel in 0..<channels { sum += data[frame * channels + channel] }
          out[frame] += sum / Float(channels)
        }
      }
      for index in 0..<frames { out[index] = min(max(out[index], -1), 1) }
      return frames
    }
  }
#endif
