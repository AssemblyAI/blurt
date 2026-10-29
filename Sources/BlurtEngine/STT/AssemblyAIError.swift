import AssemblyAI
import Foundation

// Split from `AssemblyAITranscriber.swift` to stay within the lint file-length
// budget when the over-cap fallback grew the transport. (`Duration.milliseconds`,
// the latency-logging conversion the transport's timing uses, lives in
// `Duration+Milliseconds.swift`, shared with `MicCapture`.)

/// Errors specific to the AssemblyAI transport. These get wrapped in
/// `BlurtError.sttFailed` before reaching the UI.
enum AssemblyAIError: Error, LocalizedError {
  case http(status: Int, message: String?)
  case malformedResponse
  /// The recording ended below `SyncSTTLimits.minPCMBytes`, so the body was
  /// never closed — a belt on top of `DictationSession.performRelease`'s own
  /// guard rather than the only thing between a stray tap and a request billed
  /// for transcribing nothing. `awaitUpload` maps it to the same quiet `.idle`
  /// that guard produces, so whichever layer notices first the user sees the
  /// same nothing; the description below is a backstop, not a message anyone is
  /// expected to read.
  case audioTooShort
  /// The streaming route refused the recording past its cap, and the copy that
  /// backs the buffered fallback outgrew `SyncSTTLimits.maxBufferedAudioBytes`
  /// before the recording ended — so there is no whole recording to send, and
  /// sending what was kept would paste a transcript silently missing its end.
  /// Unreachable at the capture geometry (the 20-minute recording cap is ~38 MB
  /// of PCM against a 256 MB guard); it exists so a geometry change fails here
  /// rather than in the service's own `400`.
  case recordingTooLarge

  var errorDescription: String? {
    switch self {
    case .http(let status, let message):
      if let message { return "AssemblyAI error \(status): \(message)" }
      return "AssemblyAI error \(status)"
    case .malformedResponse:
      return "Unexpected response from AssemblyAI."
    case .audioTooShort:
      return "That recording was too short to transcribe."
    case .recordingTooLarge:
      return "That recording was too large to transcribe."
    }
  }
}

// How a failed response becomes an `AssemblyAIError` — beside the error, out of
// the transport's file, for the same file-length budget.
extension AssemblyAITranscriber {
  /// Throws `AssemblyAIError.http` for a non-2xx response, carrying the
  /// service's own sentence. Shared by both requests, so a failed fallback
  /// surfaces *its* error in exactly the shape a failed live request does.
  static func requireSuccess(_ response: URLResponse, body data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      throw AssemblyAIError.http(status: http.statusCode, message: errorMessage(from: data))
    }
  }

  /// Best human-readable explanation for a non-2xx response: `error`, then
  /// `detail` (the two documented shapes — see `ErrorResponse`, which is also
  /// where the dropped `message` key is accounted for), then the raw body text,
  /// trimmed and capped.
  ///
  /// The raw-body arm is deliberately kept. It is not compatibility with an old
  /// API shape — it is what turns a response the API never promised (a proxy's HTML
  /// 502, a captive-portal page) into something diagnosable instead of a bare
  /// status code. Returns nil only for an empty body.
  static func errorMessage(from data: Data) -> String? {
    if let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data),
      let message = parsed.message
    {
      return message
    }
    guard let raw = String(bytes: data, encoding: .utf8).trimmedNonEmpty() else { return nil }
    return String(raw.prefix(500))
  }
}
