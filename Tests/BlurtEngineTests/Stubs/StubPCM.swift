import Foundation

@testable import BlurtEngine

/// Canned capture audio for the mic stubs.
///
/// Every stub that returns a PCM blob needs it to clear `DictationSession`'s
/// too-short-audio guard (`RecordingLimits.minPCMBytes`), or the transcript is
/// dropped and the suite sees a missing `.pasted` phase rather than an obviously
/// stale constant. Stated once here so raising the engine floor can't leave one
/// stub behind.
enum StubPCM {
  /// Comfortably above `RecordingLimits.minPCMBytes`, so the default
  /// press→release flow reaches transcribe.
  static let aboveMinimum = Data(count: RecordingLimits.minPCMBytes * 2)

  /// Every byte value 0...255, repeated up over `RecordingLimits.minPCMBytes` —
  /// for the byte-exactness assertions, which `aboveMinimum` (all zeros) cannot
  /// make. Here rather than in the test so raising the engine floor can't leave
  /// the pattern below it, which is the same reason `aboveMinimum` is here.
  static let everyByteValueAboveMinimum: Data = {
    let pattern = Data((0...255).map { UInt8($0) })
    let repeats = (RecordingLimits.minPCMBytes / pattern.count) + 1
    return Data(Array(repeating: pattern, count: repeats).joined())
  }()
}
