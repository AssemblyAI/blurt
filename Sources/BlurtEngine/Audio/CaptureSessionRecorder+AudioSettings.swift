@preconcurrency import AVFoundation

// The output's format request, in its own file so `CaptureSessionRecorder.swift`
// stays within the lint file-length budget — the same split `DictationSession`
// makes. macOS only: `audioSettings` is not in the iOS SDK (see the recorder).
#if os(macOS)
  extension CaptureSessionRecorder {
    /// The dictation API's geometry, converted by the output itself — the same six
    /// keys the retired WAV recorder asked of its file, so capture still lands in
    /// upload-ready S16LE with no resample pass anywhere.
    ///
    /// Every number comes from `SyncSTTLimits`, which also owns the byte math the
    /// upload side applies to the result. They are one contract: a stereo or
    /// 8-bit recorder would silently halve or double every duration the pipeline
    /// computes. Device-free, so `MicCaptureFormatTests` can assert it despite
    /// this file being coverage-excluded; a function rather than a stored static
    /// because `[String: Any]` is not `Sendable`, and it is built once per
    /// recorder regardless.
    static func audioSettings() -> [String: Any] {
      [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Double(SyncSTTLimits.sampleRate),
        AVNumberOfChannelsKey: SyncSTTLimits.channelCount,
        AVLinearPCMBitDepthKey: SyncSTTLimits.bitDepth,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ]
    }
  }
#endif
