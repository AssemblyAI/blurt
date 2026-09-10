import Foundation
import Testing

@testable import BlurtEngine

/// The wire framing of the chunked dictation upload: the three pieces of the
/// multipart body the transcriber writes, and the order they reach the server
/// in. Split from `AssemblyAITranscriberTests` to stay within the lint
/// type-body-length budget — that suite owns the round trip and the `config`
/// contents, this one owns the bytes.
@Suite("AssemblyAITranscriber multipart framing")
struct AssemblyAITranscriberMultipartTests {

  @Test("the multipart parts frame the config and audio the dictation API expects")
  func multipartFramingParts() throws {
    let head = DictationMultipart.configHead(
      config: Data(#"{"channels":1}"#.utf8), boundary: "BOUND")
    let audio = DictationMultipart.audioPartHeader(boundary: "BOUND")
    let close = DictationMultipart.closingBoundary(boundary: "BOUND")
    let headText = try #require(String(data: head, encoding: .utf8))
    let audioText = try #require(String(data: audio, encoding: .utf8))
    let closeText = try #require(String(data: close, encoding: .utf8))

    #expect(headText.hasPrefix("--BOUND\r\n"))
    #expect(closeText == "\r\n--BOUND--\r\n")
    // Field names and the filename are the contract: the server matches on them,
    // so a rename here is a 4xx that no other test would catch.
    #expect(headText.contains("Content-Disposition: form-data; name=\"config\"\r\n"))
    #expect(
      audioText.contains("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\n")
    )
    // Each part's payload sits after the blank line that ends its headers and runs
    // up to the next boundary — the CRLF placement a hand-built body gets wrong.
    // The config part terminates itself, because the audio header that follows
    // opens with its own boundary; the audio part does not, because the frames
    // after it are written straight through with no framing of their own, so its
    // terminating CRLF is the first thing in the closing boundary.
    #expect(headText.hasSuffix("Content-Type: application/json\r\n\r\n{\"channels\":1}\r\n"))
    #expect(audioText.hasPrefix("--BOUND\r\n"))
    #expect(audioText.hasSuffix("Content-Type: audio/pcm\r\n\r\n"))
  }

  @Test("the streamed body sends config first and audio last, byte-exact")
  func streamedBodyOrdersPartsAndPreservesPCM() async throws {
    // Ordering is the route's contract, not a preference: `/v1/transcribe/live`
    // rejects an audio-first body outright (the service's exact 400 is quoted
    // once, on `AssemblyAITranscriber.streamedBody`). So an accidental swap here
    // is a 400 on every dictation in production, and nothing else would catch
    // it.
    //
    // The audio part is raw S16LE, not text. Any accidental transcoding or stray
    // framing byte would corrupt the upload while string assertions still
    // passed, so the PCM covers every value 0...255 and is pinned byte-exact —
    // and clears the floor the body producer now enforces (see `streamedBody`).
    let pcm = StubPCM.everyByteValueAboveMinimum
    let transport = FakeHTTPTransport { _ in (200, json(["text": "ok"])) }
    _ = try await collectTranscript(
      makeTranscriber(apiKey: "test-key", transport: transport), pcm: pcm)

    let body = transport.uploadedBody
    let configHeader = try #require(body.range(of: Data("name=\"config\"".utf8)))
    let audioHeader = try #require(body.range(of: Data("name=\"audio\"".utf8)))
    #expect(configHeader.upperBound < audioHeader.lowerBound)
    let pcmRange = try #require(body.range(of: pcm))
    // The PCM survives intact and follows the config part, not the reverse.
    #expect(audioHeader.upperBound <= pcmRange.lowerBound)
    // Nothing but the closing boundary comes after the last audio byte — that is
    // what makes the last frame the end of the request.
    let tail = try #require(String(data: body[pcmRange.upperBound...], encoding: .utf8))
    #expect(tail == "\r\n--\(try boundary(of: body))--\r\n")
  }

  /// The boundary the transcriber generated for this request, read back out of
  /// the body's first line — it is a fresh UUID per request, so the assertion
  /// above cannot hard-code one.
  ///
  /// Sliced as bytes up to the first CRLF rather than by decoding the body and
  /// splitting it: the body carries raw PCM, so it is not valid UTF-8 and
  /// decoding the whole thing returns nil (which silently made this "").
  private func boundary(of body: Data) throws -> String {
    let firstCRLF = try #require(body.range(of: Data("\r\n".utf8)))
    let opener = try #require(String(data: body[..<firstCRLF.lowerBound], encoding: .utf8))
    return String(opener.dropFirst(2))
  }
}
