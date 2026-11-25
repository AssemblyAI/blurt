import Foundation

/// AssemblyAI's async transcription API: upload a file, submit it, poll until
/// it completes. No length cap of its own worth stating — unlike the dictation
/// API's 120 s streaming route and 20-minute buffered one — which is why a
/// whole recording goes here rather than through dictation.
///
/// Every path, header and field below is one the reference documents:
/// `POST /v2/upload` (raw bytes in, `upload_url` out), `POST /v2/transcript`
/// (`audio_url`, `speaker_labels`), `GET /v2/transcript/{id}` (`status`, `text`,
/// `utterances`, `error`). The speech model and language are left to the
/// API's defaults: `speech_models` defaults to the current models, and
/// language detection runs whenever no language is set.
public struct AsyncTranscriptionClient: Sendable {
  public static let defaultBaseURL = URL(literal: "https://api.assemblyai.com")

  /// How long to wait between status checks. The API's own guidance is a few
  /// seconds; a transcript takes a fraction of the audio's length.
  public static let pollInterval: Duration = .seconds(3)

  private let baseURL: URL
  private let transport: any HTTPTransport
  private let userAgent: String?
  private let pollInterval: Duration

  public init(
    baseURL: URL = AsyncTranscriptionClient.defaultBaseURL,
    transport: any HTTPTransport = URLSession.shared,
    userAgent: String? = nil,
    pollInterval: Duration = AsyncTranscriptionClient.pollInterval
  ) {
    self.baseURL = baseURL
    self.transport = transport
    self.userAgent = userAgent
    self.pollInterval = pollInterval
  }

  /// Where a transcription has got to, for the caller's progress line.
  public enum Phase: Sendable, Equatable {
    case uploading
    case transcribing
  }

  /// Uploads `fileURL`, transcribes it with speaker labels, and returns the
  /// completed transcript. `onPhase` hears each phase as it starts.
  /// Cancelling the calling task stops the polling; the transcript already
  /// submitted runs to completion server-side, which nothing documented stops.
  public func transcribe(
    fileAt fileURL: URL, apiKey: String, onPhase: @Sendable (Phase) -> Void = { _ in }
  ) async throws -> AsyncTranscript {
    onPhase(.uploading)
    let audioURL = try await upload(fileAt: fileURL, apiKey: apiKey)
    try Task.checkCancellation()
    onPhase(.transcribing)
    var transcript = try await submit(audioURL: audioURL, apiKey: apiKey)
    while true {
      switch transcript.status {
      case .completed:
        return transcript
      case .error:
        throw AsyncTranscriptionError.failed(transcript.error)
      case .queued, .processing:
        try await Task.sleep(for: pollInterval)
        transcript = try await fetchRetrying(id: transcript.id, apiKey: apiKey)
      }
    }
  }

  /// `POST /v2/upload`: the file's raw bytes, memory-mapped rather than read
  /// into memory, so an hours-long recording costs address space, not RAM.
  func upload(fileAt fileURL: URL, apiKey: String) async throws -> URL {
    var request = request(path: "v2/upload", apiKey: apiKey)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.httpBody = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    let data = try await retrying(when: Self.isTransient) { try await send(request) }
    return try JSONDecoder().decode(UploadResponse.self, from: data).uploadURL
  }

  /// `POST /v2/transcript` with the uploaded file and speaker labels on.
  func submit(audioURL: URL, apiKey: String) async throws -> AsyncTranscript {
    var request = request(path: "v2/transcript", apiKey: apiKey)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TranscriptRequest(audioURL: audioURL, speakerLabels: true))
    // Retried only when the API certainly created nothing: a submit that may
    // have landed (a timeout, a 5xx) is a second billed transcript if repeated.
    let data = try await retrying(when: Self.isUnsent) { try await send(request) }
    return try JSONDecoder().decode(AsyncTranscript.self, from: data)
  }

  /// How many times one request — the upload, the submit, or one status
  /// check — is tried before the transcription is given up on.
  static let pollAttempts = 4

  /// `fetch`, retried on a dropped connection, a 5xx or a 429: the transcript
  /// is still running server-side, and one blip mid-poll shouldn't cost an
  /// hour-long recording its upload. Any other 4xx is an answer, surfaced at once.
  func fetchRetrying(id: String, apiKey: String) async throws -> AsyncTranscript {
    try await retrying(when: Self.isTransient) { try await fetch(id: id, apiKey: apiKey) }
  }

  /// Runs `operation` up to `pollAttempts` times, waiting `pollInterval`
  /// between tries, for as long as `shouldRetry` calls its failure passing.
  private func retrying<T>(
    when shouldRetry: (any Error) -> Bool, _ operation: () async throws -> T
  ) async throws -> T {
    var attempt = 1
    while true {
      do {
        return try await operation()
      } catch {
        guard attempt < Self.pollAttempts, shouldRetry(error) else { throw error }
        attempt += 1
        try await Task.sleep(for: pollInterval)
      }
    }
  }

  /// Network failures that never reached the server: nothing was created, so
  /// a retry can't duplicate anything.
  private static let unsentCodes: Set<URLError.Code> = [
    .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
  ]

  /// Network failures worth one more try: the unsent ones, plus a request
  /// that was cut off or timed out on the way.
  private static let transientCodes: Set<URLError.Code> = unsentCodes.union([
    .timedOut, .networkConnectionLost, .secureConnectionFailed,
  ])

  /// A failure worth one more try: a dropped or unreachable connection, a 5xx,
  /// or a 429. Never a cancellation — `URLSession` answers a cancelled task
  /// with `URLError.cancelled`, and retrying that would keep a Library cancel
  /// waiting through every attempt.
  static func isTransient(_ error: any Error) -> Bool {
    if case AsyncTranscriptionError.http(let status, _) = error { return status == 0 || status == 429 || status >= 500 }
    guard let code = (error as? URLError)?.code else { return false }
    return transientCodes.contains(code)
  }

  /// A failure the API certainly acted on nothing for: a 429, or a connection
  /// that never reached it. The only retry safe for a non-idempotent POST.
  static func isUnsent(_ error: any Error) -> Bool {
    if case AsyncTranscriptionError.http(status: 429, _) = error { return true }
    guard let code = (error as? URLError)?.code else { return false }
    return unsentCodes.contains(code)
  }

  /// `GET /v2/transcript/{id}`.
  func fetch(id: String, apiKey: String) async throws -> AsyncTranscript {
    var request = request(path: "v2/transcript/\(id)", apiKey: apiKey)
    request.httpMethod = "GET"
    return try JSONDecoder().decode(AsyncTranscript.self, from: try await send(request))
  }

  private func request(path: String, apiKey: String) -> URLRequest {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.authorize(apiKey: apiKey, userAgent: userAgent)
    return request
  }

  private func send(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await transport.data(for: request)
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw AsyncTranscriptionError.http(status: 0, message: nil)
    }
    guard (200..<300).contains(status) else {
      let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
      throw AsyncTranscriptionError.http(status: status, message: message)
    }
    return data
  }
}

/// A transcript as `GET /v2/transcript/{id}` returns it — only the fields read.
public struct AsyncTranscript: Decodable, Sendable, Equatable {
  public enum Status: String, Decodable, Sendable {
    case queued, processing, completed, error
  }

  /// One speaker's turn, present when `speaker_labels` was on.
  public struct Utterance: Decodable, Sendable, Equatable {
    /// The API's label: "A", "B", …
    public let speaker: String
    public let text: String
  }

  public let id: String
  public let status: Status
  public let text: String?
  /// Empty when the API sends null — without speaker labels, or before it's done.
  public let utterances: [Utterance]
  public let error: String?

  enum CodingKeys: String, CodingKey {
    case id, status, text, utterances, error
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    status = try container.decode(Status.self, forKey: .status)
    text = try container.decodeIfPresent(String.self, forKey: .text)
    utterances = try container.decodeIfPresent([Utterance].self, forKey: .utterances) ?? []
    error = try container.decodeIfPresent(String.self, forKey: .error)
  }
}

enum AsyncTranscriptionError: Error, Equatable, LocalizedError {
  /// A non-2xx response, with the API's `error` sentence when it sent one.
  case http(status: Int, message: String?)
  /// The transcript finished with `status: "error"`.
  case failed(String?)

  var errorDescription: String? {
    switch self {
    case .http(let status, let message?): "AssemblyAI error \(status): \(message)"
    case .http(let status, nil): "AssemblyAI error \(status)"
    case .failed(let message?): "Transcription failed: \(message)"
    case .failed(nil): "Transcription failed."
    }
  }
}

private struct TranscriptRequest: Encodable {
  let audioURL: URL
  let speakerLabels: Bool

  enum CodingKeys: String, CodingKey {
    case audioURL = "audio_url"
    case speakerLabels = "speaker_labels"
  }
}

private struct UploadResponse: Decodable {
  let uploadURL: URL

  enum CodingKeys: String, CodingKey {
    case uploadURL = "upload_url"
  }
}
