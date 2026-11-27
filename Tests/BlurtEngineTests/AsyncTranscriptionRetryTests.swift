import Foundation
import Testing

@testable import AssemblyAI

/// The async client's retry policy: which failures earn another try, and on
/// which request — a cancel never, the upload on any blip, the submit only
/// when nothing can have been created.
@Suite("Async transcription retries")
struct AsyncTranscriptionRetryTests {
  private func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  @Test("a cancelled request is never retried; only network blips, 5xx and 429 are")
  func transientClassification() {
    #expect(!AsyncTranscriptionClient.isTransient(URLError(.cancelled)))
    #expect(!AsyncTranscriptionClient.isTransient(CancellationError()))
    #expect(!AsyncTranscriptionClient.isTransient(URLError(.badURL)))
    #expect(!AsyncTranscriptionClient.isTransient(AsyncTranscriptionError.http(status: 401, message: nil)))
    #expect(AsyncTranscriptionClient.isTransient(URLError(.timedOut)))
    #expect(AsyncTranscriptionClient.isTransient(URLError(.networkConnectionLost)))
    #expect(AsyncTranscriptionClient.isTransient(AsyncTranscriptionError.http(status: 503, message: nil)))
    #expect(AsyncTranscriptionClient.isTransient(AsyncTranscriptionError.http(status: 429, message: nil)))
    // A submit is retried only when nothing can have been created.
    #expect(AsyncTranscriptionClient.isUnsent(URLError(.cannotConnectToHost)))
    #expect(AsyncTranscriptionClient.isUnsent(AsyncTranscriptionError.http(status: 429, message: nil)))
    #expect(!AsyncTranscriptionClient.isUnsent(URLError(.timedOut)))
    #expect(!AsyncTranscriptionClient.isUnsent(URLError(.cancelled)))
    #expect(!AsyncTranscriptionClient.isUnsent(AsyncTranscriptionError.http(status: 503, message: nil)))
  }

  @Test("a cancelled status check surfaces at once, without burning the retries")
  func cancelledPollNotRetried() async throws {
    let polls = Counter()
    let transport = ScriptedTransport { request in
      switch request.url?.path {
      case "/v2/upload":
        return .success((200, json(["upload_url": "https://cdn.example/abc"])))

      case "/v2/transcript":
        return .success((200, json(["id": "t1", "status": "queued"])))

      default:
        _ = polls.next()
        return .failure(URLError(.cancelled))
      }
    }
    await #expect(throws: URLError(.cancelled)) {
      try await transcribeScratchFile(through: transport)
    }
    #expect(polls.value == 1)
  }

  @Test("a dropped upload is retried; the recording isn't lost to one blip")
  func uploadRetry() async throws {
    let uploads = Counter()
    let transport = ScriptedTransport { request in
      switch request.url?.path {
      case "/v2/upload":
        return uploads.next() == 1
          ? .failure(URLError(.networkConnectionLost))
          : .success((200, json(["upload_url": "https://cdn.example/abc"])))

      case "/v2/transcript":
        return .success((200, json(["id": "t1", "status": "queued"])))

      default:
        return .success((200, json(["id": "t1", "status": "completed", "text": "Done."])))
      }
    }
    let transcript = try await transcribeScratchFile(through: transport)
    #expect(transcript.text == "Done.")
    #expect(uploads.value == 2)
  }

  @Test(
    "a submit is retried when it never reached the API, but not after a timeout",
    arguments: [(URLError(.cannotConnectToHost), 2), (URLError(.timedOut), 1)]
  )
  func submitRetry(failure: URLError, expectedSubmits: Int) async throws {
    let submits = Counter()
    let transport = ScriptedTransport { request in
      switch request.url?.path {
      case "/v2/upload":
        return .success((200, json(["upload_url": "https://cdn.example/abc"])))

      case "/v2/transcript":
        return submits.next() == 1
          ? .failure(failure)
          : .success((200, json(["id": "t1", "status": "completed", "text": "Done."])))

      default:
        Issue.record("unexpected poll")
        return .success((500, Data()))
      }
    }
    if expectedSubmits == 1 {
      await #expect(throws: failure) { try await transcribeScratchFile(through: transport) }
    } else {
      #expect(try await transcribeScratchFile(through: transport).text == "Done.")
    }
    #expect(submits.value == expectedSubmits)
  }
}
