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
  /// AssemblyAI's latest pre-recorded model (`assemblyai-stt-3-7`) with
  /// Universal-2 fallback for languages outside 3.7's 32-language set:
  /// omitting `speech_models` on `/v2/transcript` still routes to
  /// `universal-3-5-pro`.
  static let speechModels = ["assemblyai-stt-3-7", "universal-2"]

  private let client: AsyncTranscriptionClient
  private let apiKeyProvider: @Sendable () -> String?

  @preconcurrency
  public init(apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current }) {
    self.init(client: Self.client(), apiKeyProvider: apiKeyProvider)
  }

  @preconcurrency
  public init(client: AsyncTranscriptionClient, apiKeyProvider: @escaping @Sendable () -> String?) {
    self.client = client
    self.apiKeyProvider = apiKeyProvider
  }

  /// Blurt's async client: selects Blurt's pre-recorded models and User-Agent.
  static func client(
    transport: any HTTPTransport = URLSession.shared,
    pollInterval: Duration = AsyncTranscriptionClient.pollInterval
  ) -> AsyncTranscriptionClient {
    AsyncTranscriptionClient(
      transport: transport,
      userAgent: UserAgent.current,
      pollInterval: pollInterval,
      speechModels: speechModels
    )
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
