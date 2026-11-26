public import Foundation

/// Failures every transcriber names the same way, so the pipeline can act on
/// them without knowing the provider.
public enum TranscriberError: Error, Equatable, LocalizedError {
  /// The recording ended below `RecordingLimits.minPCMBytes`, so no request was
  /// completed — a belt on top of `DictationSession.performRelease`'s own guard
  /// rather than the only thing between a stray tap and a request billed for
  /// transcribing nothing. `awaitUpload` maps it to the same quiet `.idle` that
  /// guard produces, so whichever layer notices first the user sees the same
  /// nothing; the description is a backstop, not a message anyone is expected
  /// to read.
  case audioTooShort

  public var errorDescription: String? {
    switch self {
    case .audioTooShort:
      "That recording was too short to transcribe."
    }
  }
}
