import Foundation

/// The dictation upload's multipart envelope: boundaries, part headers, the
/// `audio.pcm` filename, CRLF placement.
///
/// Its own type rather than an extension on `AssemblyAITranscriber`, because
/// none of it depends on the transcriber — boundary and bytes in, bytes out. The
/// transport is a *caller* of the envelope, which is also what keeps `framed`
/// private: as an extension split across files it had to be widened to internal
/// to stay reachable, exposing the module to a helper that is nobody's business.
///
/// Internal (not private) at the type so
/// `AssemblyAITranscriberMultipartTests` can assert the wire format against the
/// bytes. `FakeHTTPTransport` can observe the streamed body directly (it
/// collects the `AsyncThrowingStream`), but these three pieces are still where
/// the framing is stated once.
///
/// The order they go on the wire — config, audio header, frames, closing
/// boundary — is `AssemblyAITranscriber.streamedBody`'s to explain, and it is
/// the streaming route's requirement rather than a choice.
enum DictationMultipart {
  /// The `audio` part's framing — everything before the PCM bytes themselves,
  /// written once, straight after the `config` part, so the frames that follow
  /// are just audio.
  static func audioPartHeader(boundary: String) -> Data {
    framed(
      "--\(boundary)\r\n",
      "Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\n",
      "Content-Type: audio/pcm\r\n\r\n")
  }

  /// UTF-8 encodes the multipart framing. One definition for all three pieces,
  /// so the CRLF placement and part headers — the contract — are written once
  /// rather than once per piece.
  private static func framed(_ parts: String...) -> Data {
    Data(parts.joined().utf8)
  }

  /// The whole `config` part, which opens the body: its boundary, the part
  /// headers, the JSON, and the CRLF terminating the part. Written before a
  /// single audio byte — see `streamedBody` for why, and why the service cannot
  /// start without it.
  static func configHead(config: Data, boundary: String) -> Data {
    var head = framed(
      "--\(boundary)\r\n",
      "Content-Disposition: form-data; name=\"config\"\r\n",
      "Content-Type: application/json\r\n\r\n")
    head.append(config)
    head.append(framed("\r\n"))
    return head
  }

  /// Everything after the last audio frame: the `audio` part's terminating CRLF
  /// and the closing boundary — all that stands between the last frame and the
  /// request completing, which is why it carries no work.
  static func closingBoundary(boundary: String) -> Data {
    framed("\r\n", "--\(boundary)--\r\n")
  }
}
