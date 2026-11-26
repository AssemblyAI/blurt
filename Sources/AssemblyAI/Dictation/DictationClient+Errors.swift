import Foundation

// How a failed response becomes an `AssemblyAIError`, out of the transport's
// file for the lint file-length budget.
extension DictationClient {
  /// Throws `AssemblyAIError.http` for a non-2xx response, carrying the
  /// service's own sentence. Shared by both requests, so a failed fallback
  /// surfaces *its* error in exactly the shape a failed live request does.
  static func requireSuccess(_ response: URLResponse, body data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      return
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AssemblyAIError.http(status: http.statusCode, message: ErrorResponse.message(in: data))
    }
  }
}
