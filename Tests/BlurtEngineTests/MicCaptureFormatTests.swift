@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import BlurtEngine

/// Pure-logic tests for `MicCapture`'s level-metering math and recorded-file
/// decoding. The recorder capture lifecycle itself needs a real device and is
/// exercised by the env-gated `MicCaptureLevelsTests`.
@Suite("MicCapture decoding & metering")
struct MicCaptureFormatTests {
  // MARK: - dBFS → linear level

  @Test func fullScalePowerMapsToOne() {
    #expect(MicCapture.linearLevel(fromPowerDB: 0) == 1)
  }

  @Test(
    "silence at or below the meter floor maps to zero",
    arguments: [MicCapture.meterFloorDB, -80, -.infinity, .nan] as [Float])
  func silenceMapsToZero(_ powerDB: Float) {
    #expect(MicCapture.linearLevel(fromPowerDB: powerDB) == 0)
  }

  @Test func aboveFullScaleClampsToOne() {
    // dBFS can momentarily read above 0 on clipping input; the meter must pin
    // at full bars, not overshoot past the 0…1 range the overlay expects.
    #expect(MicCapture.linearLevel(fromPowerDB: 3) == 1)
  }

  @Test func midScaleMapsLinearlyInDecibels() {
    // Linear across [-50 dB, 0 dB]: halfway (-25 dB) ≈ 0.5, and louder reads higher.
    #expect(abs(MicCapture.linearLevel(fromPowerDB: -25) - 0.5) < 0.01)
    #expect(MicCapture.linearLevel(fromPowerDB: -11) > MicCapture.linearLevel(fromPowerDB: -22))
  }

  // MARK: - PCM file decoding

  @Test func decodeSamplesRoundTripsRecordedPCM() throws {
    let known: [Float] = [0, 0.5, -0.5, 1.0, -1.0, 0.25, -0.25, 0]
    let url = try Self.writeWAV(samples: known)
    defer { try? FileManager.default.removeItem(at: url) }

    let decoded = try MicCapture.decodeSamples(fromFileAt: url)

    #expect(decoded.count == known.count)
    for (got, want) in zip(decoded, known) {
      // int16 quantization tolerance (full scale is ±32767, ~3e-5 per step).
      #expect(abs(got - want) < 0.001)
    }
  }

  @Test func decodeSamplesReturnsEmptyForEmptyFile() throws {
    let url = try Self.writeWAV(samples: [])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try MicCapture.decodeSamples(fromFileAt: url).isEmpty)
  }

  @Test func noInputDeviceHasHumanReadableMessage() {
    // This message reaches the overlay via BlurtError.audioCaptureFailed's
    // interpolation of the underlying error, so it must read like a sentence,
    // not the default "(… error 0.)" gibberish a bare enum produces.
    #expect(MicCaptureError.noInputDevice.errorDescription == "No microphone is available.")
  }

  // MARK: - Helpers

  /// Write the given mono samples to a temp 16 kHz / 16-bit PCM WAV — the same
  /// on-disk format `MicCapture` records — and return its URL. The file is closed
  /// (flushed) before returning so `decodeSamples` reads a complete file.
  private static func writeWAV(samples: [Float]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("blurt-test-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    // Scoped so the AVAudioFile is released (and the file flushed) before we read.
    try {
      let file = try AVAudioFile(forWriting: url, settings: settings)
      guard !samples.isEmpty else { return }
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
      buffer.frameLength = AVAudioFrameCount(samples.count)
      for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample }
      try file.write(from: buffer)
    }()
    return url
  }
}
