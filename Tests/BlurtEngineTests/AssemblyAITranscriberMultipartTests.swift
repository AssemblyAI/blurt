import Foundation
import Testing

@testable import BlurtEngine

/// The wire framing of the chunked dictation upload: the two halves of the
/// multipart body the transcriber writes, and the order they reach the server
/// in. Split from `AssemblyAITranscriberTests` to stay within the lint
/// type-body-length budget — that suite owns the round trip and the `config`
/// contents, this one owns the bytes.
@Suite("AssemblyAITranscriber multipart framing")
struct AssemblyAITranscriberMultipartTests {

  @Test("the multipart parts frame the audio and config the dictation API expects")
  func multipartFramingParts() throws {
    let head = AssemblyAITranscriber.audioPartHeader(boundary: "BOUND")
    let tail = AssemblyAITranscriber.configTail(
      config: Data(#"{"channels":1}"#.utf8), boundary: "BOUND")
    let headText = try #require(String(data: head, encoding: .utf8))
    let tailText = try #require(String(data: tail, encoding: .utf8))

    #expect(headText.hasPrefix("--BOUND\r\n"))
    #expect(tailText.hasSuffix("--BOUND--\r\n"))
    // Field names and the filename are the contract: the server matches on them,
    // so a rename here is a 4xx that no other test would catch.
    #expect(headText.contains("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\n"))
    #expect(tailText.contains("Content-Disposition: form-data; name=\"config\"\r\n"))
    // Each part's payload sits after the blank line that ends its headers and runs
    // up to the next boundary — the CRLF placement a hand-built body gets wrong.
    // The audio part's own terminating CRLF opens the tail, because the frames in
    // between are written straight through with no framing of their own.
    #expect(headText.hasSuffix("Content-Type: audio/pcm\r\n\r\n"))
    #expect(tailText.hasPrefix("\r\n--BOUND\r\n"))
    #expect(tailText.contains("Content-Type: application/json\r\n\r\n{\"channels\":1}\r\n--BOUND--\r\n"))
  }

  @Test("the streamed body sends audio first and config last, byte-exact")
  func streamedBodyOrdersPartsAndPreservesPCM() async throws {
    // Ordering is the whole reason the request can be opened at press: `config`
    // carries the press-time context, which is only resolved once recording
    // ends, so it has to be written after the audio. The dictation API allows
    // that (it parses the body only when complete) — sync's streaming route does
    // not, so an accidental swap here is a 400 in production and nothing else
    // would catch it.
    //
    // The audio part is raw S16LE, not text. Any accidental transcoding or stray
    // framing byte would corrupt the upload while string assertions still
    // passed, so the PCM is every value 0...255 and is pinned byte-exact.
    let pcm = Data((0...255).map { UInt8($0) })
    let transport = FakeHTTPTransport { _ in (200, json(["text": "ok"])) }
    _ = try await collectTranscript(
      makeTranscriber(apiKey: "test-key", transport: transport), pcm: pcm)

    let body = transport.uploadedBody
    let audioHeader = try #require(body.range(of: Data("name=\"audio\"".utf8)))
    let configHeader = try #require(body.range(of: Data("name=\"config\"".utf8)))
    #expect(audioHeader.upperBound < configHeader.lowerBound)
    let pcmRange = try #require(body.range(of: pcm))
    // The PCM survives intact and the config part follows it, not the reverse.
    #expect(pcmRange.upperBound <= configHeader.lowerBound)
    let text = try #require(String(data: body[configHeader.lowerBound...], encoding: .utf8))
    #expect(text.hasSuffix("--\r\n"))
  }

  private func makeTranscriber(
    apiKey: String?, transport: any HTTPTransport = FakeHTTPTransport { _ in (200, Data()) }
  ) -> AssemblyAITranscriber {
    AssemblyAITranscriber(
      apiKeyProvider: { apiKey }, transport: transport,
      enhancedTranscripts: { true }, customStyle: { nil })
  }

  /// Drives one chunked dictation request off a canned frame feed — the stand-in
  /// for a live capture, which is what `transcribe` now takes.
  private func collectTranscript(
    _ transcriber: AssemblyAITranscriber, pcm: Data
  ) async throws -> String {
    try await transcriber.transcribe(
      frames: .oneShot(pcm), sampleRate: 16_000, resolveContext: { nil })
  }
}
