import Foundation
import Security
import Synchronization
import Testing

@testable import BlurtEngine

/// Storage double for `MemoizedKeyStore`: one slot, mirroring `KeychainStore`'s
/// normalization, plus a scripted read outcome so the unreadable-storage path can be
/// exercised. Counts reads and writes, which is how the memo's whole purpose —
/// *not* consulting storage twice — becomes observable.
///
/// Neither method takes the memo's lock, matching the real `KeychainStore`: `save`
/// calls both from inside `cache.withLock`, so a double that reached back into the
/// memo would deadlock rather than test anything.
final class FakeKeyStorage: Sendable {
  private struct State {
    var stored: String?
    var reads = 0
    var writes = 0
    /// Returned instead of `stored`, front-to-back, until exhausted.
    var scriptedReads: [KeychainStore.ReadResult] = []
    var writeSucceeds = true
  }

  private let state = Mutex(State())

  var stored: String? { state.withLock { $0.stored } }
  var reads: Int { state.withLock { $0.reads } }
  var writes: Int { state.withLock { $0.writes } }

  init(stored: String? = nil) {
    state.withLock { $0.stored = stored }
  }

  func scriptReads(_ outcomes: [KeychainStore.ReadResult]) {
    state.withLock { $0.scriptedReads = outcomes }
  }

  func failWrites() {
    state.withLock { $0.writeSucceeds = false }
  }

  func performRead() -> KeychainStore.ReadResult {
    state.withLock { s in
      s.reads += 1
      if !s.scriptedReads.isEmpty {
        return s.scriptedReads.removeFirst()
      }
      if let value = s.stored {
        return .value(value)
      }
      return .absent
    }
  }

  func performWrite(_ value: String?) -> Bool {
    state.withLock { s in
      s.writes += 1
      guard s.writeSucceeds else {
        return false
      }
      // `KeychainStore.write` trims and maps empty → deleted; mirror that, since the
      // memo's contract is that a read-back reflects the normalized value.
      s.stored = value.trimmedNonEmpty()
      return true
    }
  }
}
