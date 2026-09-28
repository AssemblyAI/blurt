import Foundation

public struct OpenRouterTextNormalizer: TextNormalizer {
  public static let defaultModel = "google/gemini-3.5-flash-lite"
  public static let instruction = """
    Ты — консервативный редактор русской голосовой диктовки.

    Исправь форму текста, но не переписывай мысли автора. Верни только готовый текст без
    комментариев, Markdown-обрамления и объяснений. Полностью сохраняй смысл, факты, намерение,
    последовательность мыслей и тон. Не резюмируй, не добавляй и не удаляй содержательные части.
    Исправляй пунктуацию, вопросительные знаки и естественные абзацы. Удаляй только пустые звуки,
    явные слова-паразиты без смысла и очевидный ложный старт, который говорящий сразу исправил.
    Не цензурируй. Русский текст оставляй русским. Названия технологий, моделей, продуктов, API,
    библиотек и coding-термины пиши стандартной латиницей, используя переданный technical vocabulary.
    Не превращай обычную диктовку в списки, заголовки или структурированный документ. Если текст уже
    хороший, внеси минимальные изменения.
    """

  private let apiKeyProvider: @Sendable () -> String?
  private let modelProvider: @Sendable () -> String
  private let transport: any HTTPTransport
  private let endpoint: URL

  public init(
    apiKeyProvider: @escaping @Sendable () -> String?,
    modelProvider: @escaping @Sendable () -> String = { OpenRouterModelStore().modelID },
    transport: any HTTPTransport = URLSession.shared,
    endpoint: URL = URL(staticString: "https://openrouter.ai/api/v1/chat/completions")
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.modelProvider = modelProvider
    self.transport = transport
    self.endpoint = endpoint
  }

  public func normalize(rawTranscript: String, vocabulary: [String]) async throws -> String {
    guard let key = apiKeyProvider()?.trimmedNonEmpty() else {
      throw OpenRouterError.missingAPIKey
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      Request(
        model: modelProvider(), temperature: 0,
        messages: [
          Message(role: "system", content: Self.instruction),
          Message(
            role: "user",
            content: "Technical vocabulary: \(vocabulary.joined(separator: ", "))\n\n\(rawTranscript)"),
        ]))
    let (data, response) = try await transport.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw OpenRouterError.httpStatus(http.statusCode)
    }
    guard
      let text = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content
        .trimmedNonEmpty()
    else { throw OpenRouterError.malformedResponse }
    return text
  }

  struct Message: Codable, Equatable {
    let role: String
    let content: String
  }
  struct Request: Codable, Equatable {
    let model: String
    let temperature: Double
    let messages: [Message]
  }
  struct Response: Decodable {
    struct Choice: Decodable {
      let message: Message
    }
    let choices: [Choice]
  }
}

public enum OpenRouterError: Error, Sendable, Equatable {
  case missingAPIKey
  case httpStatus(Int)
  case malformedResponse
}

public struct OpenRouterModelStore {
  private let defaults: UserDefaults
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  public static var defaultsKey: String { DefaultsKey.openRouterModel.key }
  public var modelID: String {
    defaults.string(forKey: Self.defaultsKey).trimmedNonEmpty()
      ?? OpenRouterTextNormalizer.defaultModel
  }
  public func save(_ modelID: String) {
    defaults.set(modelID.trimmedNonEmpty(), forKey: Self.defaultsKey)
  }
}
