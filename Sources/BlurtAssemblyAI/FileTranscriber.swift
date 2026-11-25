public import AssemblyAI
public import BlurtEngine
public import Foundation

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

  @preconcurrency
  public init(apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current }) {
    self.init(client: AsyncTranscriptionClient(userAgent: UserAgent.current), apiKeyProvider: apiKeyProvider)
  }

  @preconcurrency
  public init(client: AsyncTranscriptionClient, apiKeyProvider: @escaping @Sendable () -> String?) {
    self.client = client
    self.apiKeyProvider = apiKeyProvider
  }

  /// The transcript as shown and as the transforms read it: one paragraph per
  /// turn, `Speaker A: …`, when more than one person spoke
  /// (`SpeakerTurn.isMultiSpeaker`), else the plain text.
  static func text(of transcript: AsyncTranscript) -> String {
    guard SpeakerTurn.isMultiSpeaker(transcript.utterances.map(\.speaker)) else {
      return transcript.text ?? ""
    }
    return SpeakerTurn.labelled(transcript.utterances.map { SpeakerTurn(speaker: $0.speaker, text: $0.text) })
  }

  /// The transcript of the file at `url`. `onPhase` hears upload, then
  /// transcription, as each starts.
  @preconcurrency
  public func transcribe(
    fileAt url: URL,
    onPhase: @Sendable (AsyncTranscriptionClient.Phase) -> Void = { _ in
      // No phase reporting unless asked.
    }
  ) async throws -> FileTranscription {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw BlurtError.apiKeyMissing }
    let transcript = try await client.transcribe(fileAt: url, apiKey: apiKey, onPhase: onPhase)
    return FileTranscription(text: Self.text(of: transcript), plainText: transcript.text ?? "")
  }
}
