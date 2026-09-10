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
    let configPart = AssemblyAITranscriber.configPart(
      config: Data(#"{"channels":1}"#.utf8), boundary: "BOUND")
    let closing = AssemblyAITranscriber.closingBoundary(boundary: "BOUND")
    let headText = try #require(String(data: head, encoding: .utf8))
    let configText = try #require(String(data: configPart, encoding: .utf8))
    let closingText = try #require(String(data: closing, encoding: .utf8))

    #expect(configText.hasPrefix("--BOUND\r\n"))
    #expect(headText.hasPrefix("--BOUND\r\n"))
    #expect(closingText == "\r\n--BOUND--\r\n")
    // Field names and the filename are the contract: the server matches on them,
    // so a rename here is a 4xx that no other test would catch.
    #expect(headText.contains("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\n"))
    #expect(configText.contains("Content-Disposition: form-data; name=\"config\"\r\n"))
    // Each part's payload sits after the blank line that ends its headers and runs
    // up to the next boundary — the CRLF placement a hand-built body gets wrong.
    // The audio part's own terminating CRLF opens the closing boundary, because
    // the frames in between are written straight through with no framing of
    // their own.
    #expect(headText.hasSuffix("Content-Type: audio/pcm\r\n\r\n"))
    #expect(configText.hasSuffix("Content-Type: application/json\r\n\r\n{\"channels\":1}\r\n"))
  }

  @Test("the streamed body sends config first and audio last, byte-exact")
  func streamedBodyOrdersPartsAndPreservesPCM() async throws {
    // Ordering is the contract: the service decodes the audio as it arrives and
    // cannot start without the config, so an `audio` part that reaches it first
    // is a 400 on the whole request — and nothing else here would catch a swap.
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
    #expect(configHeader.upperBound < audioHeader.lowerBound)
    let pcmRange = try #require(body.range(of: pcm))
    // The PCM survives intact and follows the config part, not the reverse.
    #expect(configHeader.upperBound <= pcmRange.lowerBound)
    let text = try #require(String(data: body[pcmRange.upperBound...], encoding: .utf8))
    #expect(text.hasSuffix("--\r\n"))
  }
}
