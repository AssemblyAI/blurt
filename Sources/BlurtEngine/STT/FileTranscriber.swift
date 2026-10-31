import AssemblyAI
import Foundation

/// A file's transcript both ways: speaker-labelled, which is what opens, and
/// plain, the same words without the labels.
public struct FileTranscription: Sendable, Equatable {
  /// One paragraph per turn, `Speaker A: …`, with more than one speaker;
  /// otherwise the plain text.
  public let text: String
  public let plainText: String
}

/// Transcribes a recording — a file dropped on the main window, picked with
/// Browse…, or recorded there — through AssemblyAI's async API, so it can be
/// any length. Blurt's policy over `AsyncTranscriptionClient`: whose key, which
/// User-Agent, and how the speaker turns are written out.
///
/// **Not dictation.** Nothing here touches the dictation request, its cleanup
/// instruction or its history: a recording's transcript is a record of what
/// was said, kept in `TranscriptStore`, never request context.
public struct FileTranscriber: Sendable {
  private let client: AsyncTranscriptionClient
  private let apiKeyProvider: @Sendable () -> String?

  public init(apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current }) {
    self.init(client: AsyncTranscriptionClient(userAgent: UserAgent.current), apiKeyProvider: apiKeyProvider)
  }

  public init(client: AsyncTranscriptionClient, apiKeyProvider: @escaping @Sendable () -> String?) {
    self.client = client
    self.apiKeyProvider = apiKeyProvider
  }

  /// The transcript of the file at `url`. `onPhase` hears upload, then
  /// transcription, as each starts.
  public func transcribe(
    fileAt url: URL, onPhase: @Sendable (AsyncTranscriptionClient.Phase) -> Void = { _ in }
  ) async throws -> FileTranscription {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw BlurtError.apiKeyMissing }
    let transcript = try await client.transcribe(fileAt: url, apiKey: apiKey, onPhase: onPhase)
    return FileTranscription(text: Self.text(of: transcript), plainText: transcript.text ?? "")
  }

  /// The transcript as shown and as the transforms read it: one paragraph per
  /// turn, `Speaker A: …`, when more than one person spoke — a monologue reads
  /// better without a label on every paragraph — else the plain text.
  static func text(of transcript: AsyncTranscript) -> String {
    let speakers = Set(transcript.utterances.map(\.speaker))
    guard speakers.count > 1 else { return transcript.text ?? "" }
    return SpeakerTurn.labelled(transcript.utterances.map { SpeakerTurn(speaker: $0.speaker, text: $0.text) })
  }
}
