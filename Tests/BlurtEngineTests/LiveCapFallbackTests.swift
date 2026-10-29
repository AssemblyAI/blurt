import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// The over-cap fallback (`AssemblyAITranscriber+LiveCapFallback.swift`): a
/// recording the streaming route refuses past its 120 s cap is finished and sent
/// whole to `/v1/transcribe`. One trigger, one request, and every other outcome
/// as it was.
///
/// The audio here is small and the refusal is staged with `LiveCapTransport`:
/// what is under test is the routing — which audio reaches which request, and
/// when — not the 120 s figure, which the route enforces and the client never
/// counts.
@Suite("Live-cap fallback", .timeLimit(.minutes(1)))
struct LiveCapFallbackTests {
  /// Spoken before the refusal. Distinct byte values from `after`, so an
  /// assertion on the buffered body says which half went missing, not only that
  /// something did.
  static let before = Data(repeating: 0x11, count: 40_000)
  /// Spoken after the refusal — the audio the bug dropped.
  static let after = Data(repeating: 0x22, count: 24_000)
  /// Past the `config` part and into `before`, so the refusal lands mid-upload.
  static let refusalPoint = 30_000

  @Test("a recording the route accepts never touches the buffered route")
  func successPathUnchanged() async throws {
    let transport = LiveCapTransport(
      live: .transcript("um hello", rewrite: "Hello."), buffered: .unreachable)

    #expect(try await recordWhole(makeTranscriber(apiKey: "k", transport: transport)) == "Hello.")
    #expect(transport.bufferedRequests.isEmpty)
    #expect(try audioPart(ofStreamed: transport.liveBody) == Self.before + Self.after)
  }

  @Test("a mid-upload 413 sends everything to the buffered route, including audio after it")
  func midUploadRefusalFallsBackWithAllTheAudio() async throws {
    let transport = LiveCapTransport(
      live: .audioTooLarge, answerAfterBytes: Self.refusalPoint,
      buffered: .transcript("um all of it", rewrite: "All of it."))
    let (dictation, capture) = startSpeaking(makeTranscriber(apiKey: "k", transport: transport))

    // The user is still talking when the refusal lands; what they say next is
    // exactly what the streaming-only client dropped.
    await transport.waitUntilLiveAnswered()
    capture.yield(Self.after)
    capture.finish()

    // Treated like a streamed response: the rewrite wins, as it would there.
    #expect(try await dictation.value == "All of it.")
    let request = try #require(transport.bufferedRequests.first)
    #expect(transport.bufferedRequests.count == 1)
    #expect(request.url?.path == "/v1/transcribe")
    #expect(request.httpMethod == "POST")
    let body = try #require(request.httpBody)
    #expect(try audioPart(ofBuffered: body) == Self.before + Self.after)
    // The same config JSON and the same audio part headers as the streamed body.
    #expect(try configPart(of: body) == configPart(of: transport.liveBody))
    #expect(try #require(String(data: body, encoding: .isoLatin1)).contains(audioPartHeaders))
    #expect(request.value(forHTTPHeaderField: "Authorization") == "k")
  }

  @Test("a 413 after the whole upload falls back too")
  func refusalAfterTheUploadFallsBack() async throws {
    let transport = LiveCapTransport(
      live: .audioTooLarge, buffered: .transcript("all of it", rewrite: "All of it."))

    #expect(try await recordWhole(makeTranscriber(apiKey: "k", transport: transport)) == "All of it.")
    let request = try #require(transport.bufferedRequests.first)
    #expect(try audioPart(ofBuffered: #require(request.httpBody)) == Self.before + Self.after)
  }

  @Test("the buffered response picks verbatim text exactly as a streamed one would")
  func bufferedResponseFollowsTheEnhancedSetting() async throws {
    let transport = LiveCapTransport(
      live: .audioTooLarge, buffered: .transcript("um all of it", rewrite: "All of it."))
    let transcriber = makeTranscriber(apiKey: "k", transport: transport, enhancedTranscripts: false)

    let result = try await transcriber.transcribe(
      frames: .oneShot(Self.before), sampleRate: 16_000, context: nil)

    #expect(result == "um all of it")
  }

  /// Every refusal that is *not* the cap, mid-upload: each must surface as the
  /// same `AssemblyAIError.http` it always did, with no second request.
  static let otherFailures: [(status: Int, body: Data)] = [
    // 413 without the documented code — the `{status, title, detail}` shape.
    (413, json(["status": "413", "title": "Payload Too Large", "detail": "body too large"])),
    (413, json(["error": "something else", "error_code": "bad_request"])),
    // The code without the status.
    (400, json(["error": "audio exceeds 120000 ms", "error_code": "audio_too_large"])),
    (401, json(["detail": "Invalid API key"])),
    (502, json(["error": "upstream unavailable", "error_code": "upstream_error"])),
  ]

  @Test("any other failure surfaces as before, with no fallback request", arguments: otherFailures)
  func otherFailuresDoNotFallBack(status: Int, body: Data) async throws {
    let transport = LiveCapTransport(
      live: .init(status: status, body: body), answerAfterBytes: Self.refusalPoint,
      buffered: .unreachable)
    let (dictation, capture) = startSpeaking(makeTranscriber(apiKey: "k", transport: transport))

    #expect(try await httpFailure(of: dictation).status == status)
    #expect(transport.bufferedRequests.isEmpty)
    // And the capture is let go at once, as it was: nothing reads it any more.
    #expect(isReleased(capture))
  }

  @Test("a failed fallback surfaces its own error, not the 413")
  func failedFallbackSurfacesItsOwnError() async throws {
    let transport = LiveCapTransport(
      live: .audioTooLarge, answerAfterBytes: Self.refusalPoint,
      buffered: .init(
        status: 504, body: json(["error": "upstream timed out", "error_code": "upstream_timeout"])))
    let (dictation, capture) = startSpeaking(makeTranscriber(apiKey: "k", transport: transport))

    await transport.waitUntilLiveAnswered()
    capture.finish()

    let failure = try await httpFailure(of: dictation)
    #expect(failure.status == 504)
    #expect(failure.message == "upstream timed out")
    #expect(transport.bufferedRequests.count == 1)
  }

  @Test("a cancel while the refused recording drains sends nothing")
  func cancelDuringDrainMakesNoFallbackRequest() async throws {
    let transport = LiveCapTransport(
      live: .audioTooLarge, answerAfterBytes: Self.refusalPoint, buffered: .unreachable)
    let (dictation, capture) = startSpeaking(makeTranscriber(apiKey: "k", transport: transport))

    await transport.waitUntilLiveAnswered()
    capture.yield(Self.after)
    dictation.cancel()

    await #expect(throws: CancellationError.self) { try await dictation.value }
    #expect(transport.bufferedRequests.isEmpty)
    #expect(isReleased(capture))
  }

  @Test("a copy that would pass the byte cap fails cleanly instead of sending")
  func copyPastTheCapFailsCleanly() async throws {
    let transport = LiveCapTransport(
      live: .audioTooLarge, answerAfterBytes: Self.refusalPoint, buffered: .unreachable)
    var transcriber = makeTranscriber(apiKey: "k", transport: transport)
    transcriber.bufferedAudioByteCap = Self.before.count + Self.after.count - 1
    let (dictation, capture) = startSpeaking(transcriber)

    await transport.waitUntilLiveAnswered()
    capture.yield(Self.after)
    capture.finish()

    do {
      _ = try await dictation.value
      Issue.record("expected a throw")
    } catch AssemblyAIError.recordingTooLarge {}
    #expect(transport.bufferedRequests.isEmpty)
  }

  @Test("the byte cap bounds only the copy: the streamed request still gets everything")
  func capDoesNotTouchTheStreamedRequest() async throws {
    let transport = LiveCapTransport(
      live: .transcript("hello", rewrite: "Hello."), buffered: .unreachable)
    var transcriber = makeTranscriber(apiKey: "k", transport: transport)
    transcriber.bufferedAudioByteCap = 1

    let result = try await transcriber.transcribe(
      frames: .oneShot(Self.before), sampleRate: 16_000, context: nil)

    #expect(result == "Hello.")
    #expect(try audioPart(ofStreamed: transport.liveBody) == Self.before)
  }

  @Test("the relay keeps the whole recording under the cap and drops it past")
  func relayKeepsOrDropsTheCopy() async {
    let (live, liveFeed) = AsyncStream.makeStream(of: Data.self)
    let kept = await AssemblyAITranscriber.relay(
      .oneShot(Self.before), to: liveFeed, keepingAtMost: Self.before.count)
    #expect(kept == Self.before)
    // The streaming side got the same frame, and was ended with the feed.
    var relayed = Data()
    for await frame in live { relayed.append(frame) }
    #expect(relayed == Self.before)

    let (_, droppedFeed) = AsyncStream.makeStream(of: Data.self)
    let dropped = await AssemblyAITranscriber.relay(
      .oneShot(Self.before), to: droppedFeed, keepingAtMost: Self.before.count - 1)
    #expect(dropped == nil)
  }

  @Test("the pill reads Transcribing while the fallback is in flight, then pastes")
  func sessionShowsTranscribingThroughTheFallback() async throws {
    let hold = Gate()
    let transport = LiveCapTransport(
      live: .audioTooLarge, buffered: .transcript("um all of it", rewrite: "All of it."),
      bufferedHold: hold)
    let injector = StubInjector()
    let session = makeSession(
      transcriber: makeTranscriber(apiKey: "k", transport: transport), injector: injector)

    await session.press()
    await session.release()
    await hold.waitUntilEntered()
    #expect(await session.phase == .transcribing)
    hold.allowToFinish()
    await session.waitForIdle()

    #expect(await session.phase == .pasted)
    #expect(await injector.inserted == ["All of it."])
  }
}

// MARK: - Helpers

extension LiveCapFallbackTests {
  /// The audio part's headers, which the buffered body must carry verbatim:
  /// same part name, same `audio.pcm` filename, same `audio/pcm` type.
  var audioPartHeaders: String {
    "Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\nContent-Type: audio/pcm\r\n\r\n"
  }

  /// Opens a dictation and says `before` into it, leaving the recording open:
  /// what happens next — more audio, key up, a cancel — is the test's to decide.
  func startSpeaking(
    _ transcriber: AssemblyAITranscriber
  ) -> (dictation: Task<String, any Error>, capture: AsyncStream<Data>.Continuation) {
    let (feed, capture) = AsyncStream.makeStream(of: Data.self)
    let dictation = Task {
      try await transcriber.transcribe(frames: feed, sampleRate: 16_000, context: nil)
    }
    capture.yield(Self.before)
    return (dictation, capture)
  }

  /// A whole recording — `before`, then `after`, then key up — with nothing
  /// staged in between.
  func recordWhole(_ transcriber: AssemblyAITranscriber) async throws -> String {
    let (dictation, capture) = startSpeaking(transcriber)
    capture.yield(Self.after)
    capture.finish()
    return try await dictation.value
  }

  /// The `AssemblyAIError.http` a dictation ended in; any other outcome fails the test.
  func httpFailure(
    of dictation: Task<String, any Error>
  ) async throws -> (status: Int, message: String?) {
    do {
      _ = try await dictation.value
    } catch let AssemblyAIError.http(status, message) {
      return (status, message)
    }
    Issue.record("expected AssemblyAIError.http")
    return (0, nil)
  }

  /// Whether nothing reads the capture feed any more — the state a real
  /// recorder's feed is left in once the transcription is over, so later
  /// frames are dropped instead of buffered.
  func isReleased(_ capture: AsyncStream<Data>.Continuation) -> Bool {
    if case .terminated = capture.yield(Data([0])) { return true }
    return false
  }

  /// The PCM between the audio part's headers and the closing boundary of a
  /// whole multipart body.
  func audioPart(ofBuffered body: Data) throws -> Data {
    let start = try #require(body.range(of: Data(audioPartHeaders.utf8))).upperBound
    let end = try #require(body.range(of: Data("\r\n--".utf8), options: .backwards)).lowerBound
    return body[start..<end]
  }

  /// The PCM a streamed body carried — everything after the audio part's
  /// headers, up to the closing boundary when the body was completed.
  func audioPart(ofStreamed body: Data) throws -> Data {
    let start = try #require(body.range(of: Data(audioPartHeaders.utf8))).upperBound
    let end = body.range(of: Data("\r\n--".utf8), options: .backwards, in: start..<body.endIndex)?.lowerBound
    return body[start..<(end ?? body.endIndex)]
  }

  /// The `config` part's JSON.
  func configPart(of body: Data) throws -> Data {
    let start = try #require(body.range(of: Data("application/json\r\n\r\n".utf8))).upperBound
    let end = try #require(body.range(of: Data("\r\n--".utf8), in: start..<body.endIndex)).lowerBound
    return body[start..<end]
  }
}
