import Foundation
import os

/// Per-request `URLSessionTaskDelegate` that logs the dictation round-trip's latency
/// breakdown from `URLSessionTaskMetrics`: how much was connection setup
/// (DNS/TCP/TLS — warmable by pre-connecting at record-start) versus server
/// inference (`ttfbMs` ≈ requestStart→responseStart). `reused=true` means the
/// pooled connection was hot, so setup was ~free. Best-effort: any timestamp the
/// transport doesn't report is logged as `n/a`. Holds only immutable state, so
/// `@unchecked Sendable` is sound for the delegate-queue callback.
final class DictationUploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let log: Logger

  init(log: Logger = SDKLog.dictation) {
    self.log = log
  }

  /// Refuses to hand `URLSession` a second copy of the request body.
  ///
  /// `URLSession` asks for a fresh body stream whenever it has to send the
  /// request again — an auth challenge, a 307, a connection retry it handles
  /// internally. A recording that has already been streamed to the server is
  /// gone from this body: the copy the over-cap fallback keeps backs a second,
  /// separate request to `/v1/transcribe`, taken only on the streaming route's
  /// `413 audio_too_large`, and is never fed back into this one. Returning nil fails
  /// the request loudly instead of quietly re-sending it with an empty body and
  /// handing back a blank transcript.
  ///
  /// `async` stays though nothing is awaited: the async variant is the delegate method
  /// URLSession looks for, and a synchronous one would never be called.
  func urlSession(
    _: URLSession,
    needNewBodyStreamForTask _: URLSessionTask
  ) async -> InputStream? {  // swiftlint:disable:this async_without_await
    log.error(
      "URLSession asked to replay the upload body; a streamed recording can't be replayed"
    )
    return nil
  }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    guard let transaction = metrics.transactionMetrics.last else {
      return
    }
    func ms(_ from: Date?, _ to: Date?) -> String {
      guard let from, let to else {
        return "n/a"
      }
      return unsafe String(format: "%.0f", to.timeIntervalSince(from) * 1_000)
    }
    log.info(
      """
      dictation metrics reused=\(transaction.isReusedConnection, privacy: .public) \
      dnsMs=\(ms(transaction.domainLookupStartDate, transaction.domainLookupEndDate), privacy: .public) \
      connectMs=\(ms(transaction.connectStartDate, transaction.connectEndDate), privacy: .public) \
      tlsMs=\(ms(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate), privacy: .public) \
      ttfbMs=\(ms(transaction.requestStartDate, transaction.responseStartDate), privacy: .public) \
      totalMs=\(ms(transaction.fetchStartDate, transaction.responseEndDate), privacy: .public)
      """
    )
  }
}
