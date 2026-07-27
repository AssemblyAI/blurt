import Foundation

@testable import BlurtEngine

/// Canned capture audio for the mic stubs.
///
/// Every stub that returns a PCM blob needs it to clear `DictationSession`'s
/// too-short-audio guard (`SyncSTTLimits.minPCMBytes`), or the transcript is
/// dropped and the suite sees a missing `.pasted` phase rather than an obviously
/// stale constant. Stated once here so raising the engine floor can't leave one
/// stub behind.
enum StubPCM {
  /// Comfortably above `SyncSTTLimits.minPCMBytes`, so the default
  /// press→release flow reaches transcribe.
  static let aboveMinimum = Data(count: SyncSTTLimits.minPCMBytes * 2)
}
