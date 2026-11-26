import AssemblyAI
import Foundation

/// Runs `body` with one small file for an async client to "upload", in a fresh
/// temporary directory removed when `body` returns.
@discardableResult
func withScratchAudioFile<T>(_ body: (URL) async throws -> T) async throws -> T {
  try await withTemporaryDirectory(named: "AsyncUpload") { directory in
    let url = directory.appending(path: "call.m4a")
    try Data("audio bytes".utf8).write(to: url)
    return try await body(url)
  }
}

/// A scratch file transcribed by the async client over `transport`, with no
/// wait between status checks — the whole flow, for a test about how it ends.
func transcribeScratchFile(through transport: any HTTPTransport) async throws -> AsyncTranscript {
  try await withScratchAudioFile { url in
    try await AsyncTranscriptionClient(transport: transport, pollInterval: .zero)
      .transcribe(fileAt: url, apiKey: "key")
  }
}
