import Foundation
import Synchronization

@testable import BlurtEngine

/// A `PCMSink` that records what it's asked to do instead of playing it. For
/// the pacing tests, `bufferedSeconds` can be set, and `bufferedAfterEnqueue`
/// makes each enqueue report that much audio queued, as a real player would;
/// `roomChecks` counts the speaker asking, so a test can wait for the check
/// that holds the next piece back rather than sleeping past it.
final class RecordingSink: PCMSink {
  struct Record {
    var chunks: [Data] = []
    var drained = false
    var stopped = false
    var buffered: Double = 0
    var bufferedAfterEnqueue: Double?
    var roomChecks = 0
  }

  let record = Mutex(Record())

  var chunks: [Data] { record.withLock(\.chunks) }
  var drained: Bool { record.withLock(\.drained) }
  var stopped: Bool { record.withLock(\.stopped) }
  var roomChecks: Int { record.withLock(\.roomChecks) }
  /// Silent: the meter isn't what these tests read.
  var currentLevel: Float { 0 }
  var bufferedSeconds: Double {
    get {
      record.withLock { record in
        record.roomChecks += 1
        return record.buffered
      }
    }
    set { record.withLock { $0.buffered = newValue } }
  }
  /// Everything counts as heard the moment it's enqueued: a clip is never trimmed.
  var unplayedAudioSeconds: Double { 0 }
  var bufferedAfterEnqueue: Double? {
    get { record.withLock(\.bufferedAfterEnqueue) }
    set { record.withLock { $0.bufferedAfterEnqueue = newValue } }
  }

  func enqueue(_ pcm: Data) {
    record.withLock { record in
      record.chunks.append(pcm)
      if let queued = record.bufferedAfterEnqueue { record.buffered = queued }
    }
  }
  func drain() { record.withLock { $0.drained = true } }
  func stop() { record.withLock { $0.stopped = true } }
}
