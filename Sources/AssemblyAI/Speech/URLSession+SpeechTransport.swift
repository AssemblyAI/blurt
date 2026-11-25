public import Foundation

extension URLSession: SpeechTransport {
  /// Hands the body on in the blocks URLSession delivers (`SpeechStreamDelegate`)
  /// rather than a byte at a time: a long read is millions of bytes.
  ///
  /// The delegate is attached before anything can cancel the task, and a
  /// cancellation settles the head itself rather than counting on URLSession
  /// to report one: a task cancelled before it was resumed (the caller already
  /// cancelled, so `onCancel` runs before the operation) may never call back,
  /// and the wait for the head would never end.
  public func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
    try Task.checkCancellation()
    let (body, feed) = AsyncThrowingStream<Data, any Error>.makeStream()
    let delegate = SpeechStreamDelegate(body: feed)
    let task = dataTask(with: request)
    task.delegate = delegate
    feed.onTermination = { _ in task.cancel() }
    let response = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
        // Already settled (cancelled first): the request is never sent.
        if delegate.arm(continuation) { task.resume() }
      }
    } onCancel: {
      task.cancel()
      delegate.fail(CancellationError())
    }
    return (response, body)
  }
}
