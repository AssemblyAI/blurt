import Foundation
import os

// The chunked upload's instrumentation, split from `AssemblyAITranscriber.swift`
// to stay within the lint file-length budget (like `DictationWireTypes.swift`,
// which took the JSON contract). What the body producer measures on its way
// past, and the per-task delegate that reports it.

/// Per-request `URLSessionTaskDelegate` that logs the dictation round-trip's latency
/// breakdown from `URLSessionTaskMetrics`: how much was connection setup
/// (DNS/TCP/TLS — warmable by pre-connecting at record-start) versus server
/// inference (`ttfbMs` ≈ requestStart→responseStart). `reused=true` means the
/// pooled connection was hot, so setup was ~free. Best-effort: any timestamp the
/// transport doesn't report is logged as `n/a`. Holds only immutable state, so
/// `@unchecked Sendable` is sound for the delegate-queue callback.
///
/// Internal rather than file-private now that it lives beside the transcriber
/// rather than inside its file.
final class MetricsLogger: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let progress: UploadProgress
  init(progress: UploadProgress) { self.progress = progress }

  /// Refuses to hand `URLSession` a second copy of the request body.
  ///
  /// `URLSession` asks for a fresh body stream whenever it has to send the
  /// request again — an auth challenge, a 307, a connection retry it handles
  /// internally. A recording that has already been streamed to the server is
  /// gone: there is no buffered copy to replay, by design. Returning nil fails
  /// the request loudly instead of quietly re-sending it with an empty body and
  /// letting the user watch a dictation come back blank.
  func urlSession(
    _ session: URLSession, needNewBodyStreamForTask task: URLSessionTask
  ) async -> InputStream? {
    transcriberLog.error(
      "URLSession asked to replay the upload body; a streamed recording can't be replayed")
    return nil
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    guard let transaction = metrics.transactionMetrics.last else { return }
    func ms(_ from: Date?, _ to: Date?) -> String {
      guard let from, let to else { return "n/a" }
      return String(format: "%.0f", to.timeIntervalSince(from) * 1000)
    }
    transcriberLog.info(
      """
      dictation metrics audioMs=\(SyncSTTLimits.durationMs(ofPCMBytes: self.progress.audioBytes), privacy: .public) \
      reused=\(transaction.isReusedConnection, privacy: .public) \
      dnsMs=\(ms(transaction.domainLookupStartDate, transaction.domainLookupEndDate), privacy: .public) \
      connectMs=\(ms(transaction.connectStartDate, transaction.connectEndDate), privacy: .public) \
      tlsMs=\(ms(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate), privacy: .public) \
      ttfbMs=\(ms(transaction.requestStartDate, transaction.responseStartDate), privacy: .public) \
      totalMs=\(ms(transaction.fetchStartDate, transaction.responseEndDate), privacy: .public)
      """
    )
  }
}
