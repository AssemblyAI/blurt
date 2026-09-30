import Foundation
import Synchronization

@testable import BlurtEngine

/// Plays the TTS service's side of the socket. Each command the synthesizer
/// sends is passed to `respond`, and the frames it returns are queued for
/// `receive()`, the same way the live service answers a `Flush` with `Audio`
/// then `FlushDone`. A `receive()` with nothing queued suspends until more
/// arrives or the socket is closed, so a responder that returns nothing models a
/// server that never answers.
actor FakeSpeechSocket: SpeechSocket {
  struct Record {
    var sent: [String] = []
    /// nil while open; otherwise whether `close` was the normal (post-Terminate) kind.
    var closedNormally: Bool?
  }

  nonisolated let record = Mutex(Record())
  private let respond: @Sendable (String) -> [String]
  private let feed: AsyncStream<String>.Continuation
  private var incoming: AsyncStream<String>.Iterator

  init(respond: @escaping @Sendable (String) -> [String]) {
    self.respond = respond
    let (stream, feed) = AsyncStream<String>.makeStream()
    self.feed = feed
    self.incoming = stream.makeAsyncIterator()
  }

  func send(_ text: String) async throws {
    guard record.withLock({ $0.closedNormally == nil }) else { throw URLError(.networkConnectionLost) }
    record.withLock { $0.sent.append(text) }
    for frame in respond(text) { feed.yield(frame) }
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    var iterator = incoming
    let next = await iterator.next(isolation: #isolation)
    incoming = iterator
    guard let next else { throw URLError(.networkConnectionLost) }
    return .string(next)
  }

  nonisolated func close(normally: Bool) {
    record.withLock { if $0.closedNormally == nil { $0.closedNormally = normally } }
    feed.finish()
  }

  /// Drops the connection from the server's side.
  nonisolated func drop() { feed.finish() }

  nonisolated var sent: [String] { record.withLock(\.sent) }
  nonisolated var closedNormally: Bool? { record.withLock(\.closedNormally) }

  static func audio(_ bytes: [UInt8]) -> String {
    #"{"type":"Audio","audio":"\#(Data(bytes).base64EncodedString())"}"#
  }

  static let flushDone = #"{"type":"FlushDone"}"#

  /// The live service's answer to each command: nothing for `Generate` (it
  /// only buffers), one audio chunk then an ack for `Flush`, numbered by flush.
  static func service() -> @Sendable (String) -> [String] {
    let flushes = Counter()
    return { command in
      guard command.contains(#""Flush""#) else { return [] }
      let index = flushes.next()
      return [audio([UInt8(index), 0]), flushDone]
    }
  }
}

/// A `PCMSink` that records what it's asked to do instead of playing it.
final class RecordingSink: PCMSink {
  struct Record {
    var chunks: [Data] = []
    var drained = false
    var stopped = false
  }

  let record = Mutex(Record())

  func enqueue(_ pcm: Data) { record.withLock { $0.chunks.append(pcm) } }
  func drain() async { record.withLock { $0.drained = true } }
  func stop() { record.withLock { $0.stopped = true } }

  var chunks: [Data] { record.withLock(\.chunks) }
  var drained: Bool { record.withLock(\.drained) }
  var stopped: Bool { record.withLock(\.stopped) }
}
