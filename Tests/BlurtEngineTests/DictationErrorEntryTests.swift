import Foundation
import Testing

@testable import BlurtEngine

/// What one failure records. Driven through `makeErrorEntry`, because each of
/// these is a question about the entry rather than the file — including the one
/// that matters most: that the text the user was editing is nowhere in it. Asked
/// of a written line, that was `!line.contains("hunter2")` against a helper that
/// returns `""` on any read failure, so it also passed when nothing had been
/// written.
@Suite("DictationLog.makeErrorEntry")
struct DictationErrorEntryTests {
  private let context = TranscriptionContext(
    appName: "1Password",
    priorText: "hunter2",
    windowTitle: "Vault",
    fieldLabel: "Password",
    selectedText: "s3cret"
  )

  @Test("records the stable kind, the human description, and a timestamp")
  func kindDescriptionAndTimestamp() {
    let entry = DictationLog.makeErrorEntry(
      .apiKeyMissing, context: nil, now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(entry.kind == "apiKeyMissing")
    #expect(entry.error == BlurtError.apiKeyMissing.errorDescription)
    #expect(entry.ts.hasPrefix("2023-11-14"))
  }

  /// The reason `error` is recorded in full and not just `kind`: for a
  /// transcription failure the underlying error carries the API status code and
  /// server message, which is the whole diagnosis.
  @Test("keeps the wrapped error's description for .sttFailed")
  func keepsUnderlyingDescription() {
    let underlying = NSError(
      domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "AssemblyAI error 429"]
    )
    let entry = DictationLog.makeErrorEntry(
      .sttFailed(underlying: underlying), context: nil, now: Date()
    )
    #expect(entry.kind == "sttFailed")
    #expect(entry.error.contains("AssemblyAI error 429"))
  }

  @Test("threads the focus context's app, window, and field")
  func threadsDiagnosticContext() {
    let entry = DictationLog.makeErrorEntry(.targetAppLost, context: context, now: Date())
    #expect(entry.app == "1Password")
    #expect(entry.window == "Vault")
    #expect(entry.field == "Password")
  }

  /// The error log is diagnostics-only: the text the user was editing explains
  /// nothing about a failure and is the most sensitive part of the snapshot, so
  /// the entry has no field to put it in. Reflecting over the encoded keys says
  /// so positively — a `prior` field added later fails this rather than silently
  /// starting to log passwords.
  @Test("has no field for prior text, selected text, or the assembled prompt")
  func carriesNoSurroundingText() throws {
    let entry = DictationLog.makeErrorEntry(.targetAppLost, context: context, now: Date())
    let data = try DictationLog.makeEncoder().encode(entry)
    let object = try JSONSerialization.jsonObject(with: data)
    let encoded = try #require(object as? [String: Any])
    #expect(encoded.keys.sorted() == ["app", "error", "field", "kind", "ts", "window"])
  }

  @Test("leaves the context fields nil when nothing was captured")
  func noContextLeavesFieldsNil() {
    let entry = DictationLog.makeErrorEntry(.apiKeyMissing, context: nil, now: Date())
    #expect(entry.app == nil)
    #expect(entry.window == nil)
    #expect(entry.field == nil)
  }
}
