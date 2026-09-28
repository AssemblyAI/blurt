import Foundation

public struct AssemblyAILongTranscriber: LongSTTClient {
  private let apiKeyProvider: @Sendable () -> String?
  private let transport: any HTTPTransport
  private let baseURL: URL
  private let pollDelay: Duration

  public init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    transport: any HTTPTransport = URLSession.shared,
    baseURL: URL = URL(staticString: "https://api.assemblyai.com"),
    pollDelay: Duration = .seconds(2)
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.transport = transport
    self.baseURL = baseURL
    self.pollDelay = pollDelay
  }

  public func transcribe(audioFileURL: URL, vocabulary: [String]) async throws -> String {
    guard let key = apiKeyProvider()?.trimmedNonEmpty() else {
      throw BlurtError.apiKeyMissing
    }
    let audio = try Data(contentsOf: audioFileURL, options: .mappedIfSafe)
    let upload: UploadResponse = try await send(
      path: "v2/upload", method: "POST", key: key, body: audio,
      contentType: "application/octet-stream")
    let submitted: TranscriptResponse = try await sendJSON(
      path: "v2/transcript", method: "POST", key: key,
      value: TranscriptRequest(
        audioURL: upload.uploadURL, speechModels: ["universal-2"],
        languageCode: "ru", wordBoost: VocabularyStore.deduplicated(vocabulary)))
    var current = submitted
    while current.status == "queued" || current.status == "processing" {
      try Task.checkCancellation()
      try await Task.sleep(for: pollDelay)
      current = try await send(
        path: "v2/transcript/\(current.id)", method: "GET", key: key,
        body: nil, contentType: nil)
    }
    guard current.status == "completed", let text = current.text?.trimmedNonEmpty() else {
      throw AssemblyAILongError.transcriptionFailed(current.error)
    }
    return text
  }

  private func sendJSON<T: Encodable, R: Decodable>(
    path: String, method: String, key: String, value: T
  ) async throws -> R {
    try await send(
      path: path, method: method, key: key,
      body: JSONEncoder().encode(value), contentType: "application/json")
  }

  private func send<R: Decodable>(
    path: String, method: String, key: String, body: Data?, contentType: String?
  ) async throws -> R {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = method
    request.timeoutInterval = 90
    request.httpBody = body
    request.setValue(key, forHTTPHeaderField: "Authorization")
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    request.setUserAgent()
    let (data, response) = try await transport.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw AssemblyAILongError.httpStatus(http.statusCode)
    }
    return try JSONDecoder().decode(R.self, from: data)
  }

  struct TranscriptRequest: Encodable, Equatable {
    let audioURL: String
    let speechModels: [String]
    let languageCode: String
    let wordBoost: [String]
    enum CodingKeys: String, CodingKey {
      case audioURL = "audio_url"
      case speechModels = "speech_models"
      case languageCode = "language_code"
      case wordBoost = "word_boost"
    }
  }
  struct UploadResponse: Decodable {
    let uploadURL: String
    enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" }
  }
  struct TranscriptResponse: Decodable {
    let id: String
    let status: String
    let text: String?
    let error: String?
  }
}

public enum AssemblyAILongError: Error, Sendable, Equatable {
  case httpStatus(Int)
  case transcriptionFailed(String?)
}
