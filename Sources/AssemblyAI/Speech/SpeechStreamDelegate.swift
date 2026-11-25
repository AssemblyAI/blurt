import Foundation
import Synchronization

/// One streamed request's delegate: resumes the caller's wait for the head
/// once it arrives (or the failure, if it never does), then feeds each block
/// of the body to `body` and finishes it with the request.
///
/// The outcome and the wait meet in either order: one that settles before
/// `arm` is kept and handed over when the wait arrives, so the continuation is
/// resumed exactly once whatever races.
final class SpeechStreamDelegate: NSObject, URLSessionDataDelegate, Sendable {
  private enum Head {
    case pending
    case waiting(CheckedContinuation<HTTPURLResponse, any Error>)
    case settled(Result<HTTPURLResponse, any Error>)
    case delivered
  }

  private let head = Mutex(Head.pending)
  private let body: AsyncThrowingStream<Data, any Error>.Continuation

  init(body: AsyncThrowingStream<Data, any Error>.Continuation) {
    self.body = body
  }

  /// Waits on the head with `continuation`. False when the outcome was
  /// already in — it's delivered now, and there is nothing left to start.
  func arm(_ continuation: CheckedContinuation<HTTPURLResponse, any Error>) -> Bool {
    let early: Result<HTTPURLResponse, any Error>? = head.withLock { head in
      switch head {
      case .pending:
        head = .waiting(continuation)
        return nil

      case .settled(let outcome):
        head = .delivered
        return outcome

      case .waiting, .delivered:
        return .failure(CancellationError())
      }
    }
    guard let early else {
      return true
    }
    continuation.resume(with: early)
    return false
  }

  /// Ends the request with `error`, before the head if it hasn't come yet.
  func fail(_ error: any Error) {
    settle(.failure(error))
    body.finish(throwing: error)
  }

  func settle(_ outcome: Result<HTTPURLResponse, any Error>) {
    let waiting: CheckedContinuation<HTTPURLResponse, any Error>? = head.withLock { head in
      switch head {
      case .pending:
        head = .settled(outcome)
        return nil

      case .waiting(let continuation):
        head = .delivered
        return continuation

      case .settled, .delivered:
        return nil
      }
    }
    waiting?.resume(with: outcome)
  }

  // `async` stays though nothing is awaited: the async variant is the delegate method
  // URLSession looks for, and a synchronous one would never be called.
  func urlSession(
    _: URLSession,
    dataTask _: URLSessionDataTask,
    didReceive response: URLResponse
  ) async -> URLSession.ResponseDisposition {  // swiftlint:disable:this async_without_await
    if let http = response as? HTTPURLResponse {
      settle(.success(http))
      return .allow
    }
    settle(.failure(URLError(.badServerResponse)))
    return .cancel
  }

  func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
    body.yield(data)
  }

  func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
    settle(.failure(error ?? URLError(.badServerResponse)))
    if let error { body.finish(throwing: error) } else { body.finish() }
  }
}
