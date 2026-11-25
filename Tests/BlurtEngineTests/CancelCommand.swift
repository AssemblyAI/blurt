import Foundation
import Testing

@testable import BlurtEngine

// Guard/no-op behaviors and phase-stream supersession live in
// `DictationSessionGuardTests.swift` (same collaborators and stubs), split out
// to stay within the lint file-length budget. The `onTranscriptDelivered`
// side-channel tests live in `DictationSessionTranscriptTests.swift`, and the
// `.connecting` bring-up window in `DictationSessionBringUpTests.swift`, for the
// same reason.

/// `DictationSession`'s two cancel entry points, for a test that holds both to the
/// same outcome.
enum CancelCommand: CaseIterable, Sendable {
  case cancel
  case cancelRecording

  func send(to session: DictationSession) async {
    switch self {
    case .cancel:
      await session.cancel()

    case .cancelRecording:
      await session.cancelRecording()
    }
  }
}
