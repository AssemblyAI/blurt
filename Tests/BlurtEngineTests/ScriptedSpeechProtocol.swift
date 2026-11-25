import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A `URLProtocol` playing one scripted response, registered only on the
/// private sessions `SpeechTransportTests` builds (never globally).
final class ScriptedSpeechProtocol: URLProtocol, @unchecked Sendable {
  enum Script: Sendable {
    case respond(status: Int, chunks: [Data], finishes: Bool)
    case respondThenFail(chunk: Data, URLError)
    case fail(URLError)
  }

  private struct State {
    var script = Script.fail(URLError(.unknown))
    var started = false
    var stopped = false
  }

  private static let state = Mutex(State())

  static var started: Bool { state.withLock(\.started) }
  static var stopped: Bool { state.withLock(\.stopped) }

  static func play(_ script: Script) {
    state.withLock { $0 = State(script: script) }
  }

  override static func canInit(with _: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let script = Self.state.withLock { state in
      state.started = true
      return state.script
    }
    let url = request.url ?? AssemblyAISpeechSynthesizer.endpoint
    switch script {
    case let .respond(status, chunks, finishes):
      respond(status: status, url: url)
      for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
      if finishes { client?.urlProtocolDidFinishLoading(self) }

    case let .respondThenFail(chunk, error):
      respond(status: 200, url: url)
      client?.urlProtocol(self, didLoad: chunk)
      // A moment later, as a real connection drops after audio has flowed:
      // failing in the same instant, URLSession reports only the failure.
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
        client?.urlProtocol(self, didFailWithError: error)
      }

    case .fail(let error):
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {
    Self.state.withLock { $0.stopped = true }
  }

  /// With the content type the service sends: without one, URLSession sniffs
  /// the body before reporting the response, holding it back until enough of
  /// the body (or its end) arrives.
  private func respond(status: Int, url: URL) {
    let type = status == 200 ? "audio/pcm;rate=24000;channels=1" : "application/json"
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type]
      )
    else {
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }
}
