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
private final class FakeKeyStorage: Sendable {
  private struct State {
    var stored: String?
    var reads = 0
    var writes = 0
    /// Returned instead of `stored`, front-to-back, until exhausted.
    var scriptedReads: [KeychainStore.ReadResult] = []
    var writeSucceeds = true
  }
  private let state = Mutex(State())

  init(stored: String? = nil) {
    state.withLock { $0.stored = stored }
  }

  var stored: String? { state.withLock { $0.stored } }
  var reads: Int { state.withLock { $0.reads } }
  var writes: Int { state.withLock { $0.writes } }

  func scriptReads(_ outcomes: [KeychainStore.ReadResult]) {
    state.withLock { $0.scriptedReads = outcomes }
  }

  func failWrites() {
    state.withLock { $0.writeSucceeds = false }
  }

  func performRead() -> KeychainStore.ReadResult {
    state.withLock { s in
      s.reads += 1
      if !s.scriptedReads.isEmpty { return s.scriptedReads.removeFirst() }
      if let value = s.stored { return .value(value) }
      return .absent
    }
  }

  func performWrite(_ value: String?) -> Bool {
    state.withLock { s in
      s.writes += 1
      guard s.writeSucceeds else { return false }
      // `KeychainStore.write` trims and maps empty → deleted; mirror that, since the
      // memo's contract is that a read-back reflects the normalized value.
      s.stored = value.trimmedNonEmpty()
      return true
    }
  }
}

private func makeStore(_ storage: FakeKeyStorage) -> MemoizedKeyStore {
  MemoizedKeyStore(read: { storage.performRead() }, write: { storage.performWrite($0) })
}

/// The memo in front of the API key's storage. Both cases this suite exists for are
/// regressions: a real lockout bug and a real memo/storage-disagreement bug, neither
/// of which had any coverage while the keychain item and the memo were both
/// process-global statics.
@Suite("MemoizedKeyStore")
struct MemoizedKeyStoreTests {
  // MARK: - reading

  @Test("a stored key is read once and served from the memo after that")
  func memoizesAStoredKey() {
    let storage = FakeKeyStorage(stored: "sk-123")
    let store = makeStore(storage)
    #expect(store.current == "sk-123")
    #expect(store.current == "sk-123")
    #expect(store.current == "sk-123")
    // The point of the memo: the readiness check runs on every hotkey press, and
    // each miss was a synchronous SecItemCopyMatching in the press→recording path.
    #expect(storage.reads == 1)
  }

  @Test("an absent key is memoized too, so the hot path doesn't re-ask")
  func memoizesAbsence() {
    let storage = FakeKeyStorage(stored: nil)
    let store = makeStore(storage)
    #expect(store.current == nil)
    #expect(store.current == nil)
    // `.absent` is a durable fact ("nothing saved"), so caching it is correct —
    // otherwise a user who hasn't set up yet pays a keychain read per press.
    #expect(storage.reads == 1)
  }

  @Test("an unreadable read is never memoized, so the next read retries")
  func doesNotMemoizeUnavailable() {
    // THE LOCKOUT REGRESSION. A locked login keychain, or a denied ACL prompt (which
    // re-signing the app forces), used to be cached as "no API key" for the rest of
    // the process: the wizard claimed setup was incomplete and every press failed
    // `.apiKeyMissing`, with no way back short of relaunching or retyping the key.
    let storage = FakeKeyStorage(stored: "sk-123")
    storage.scriptReads([.unavailable(errSecInteractionNotAllowed)])
    let store = makeStore(storage)

    #expect(store.current == nil)  // can't read it — report no key for now
    #expect(store.current == "sk-123")  // …and recover the moment storage works
    #expect(storage.reads == 2)
  }

  @Test("a run of unreadable reads keeps retrying rather than latching")
  func retriesEveryUnavailableRead() {
    let storage = FakeKeyStorage(stored: "sk-123")
    storage.scriptReads(Array(repeating: .unavailable(errSecAuthFailed), count: 3))
    let store = makeStore(storage)

    #expect(store.current == nil)
    #expect(store.current == nil)
    #expect(store.current == nil)
    #expect(store.current == "sk-123")
    #expect(storage.reads == 4)
  }

  // MARK: - writing

  @Test("save writes, then reads back so the memo matches storage")
  func saveRefreshesTheMemoFromStorage() {
    let storage = FakeKeyStorage()
    let store = makeStore(storage)

    #expect(store.save("  sk-new  "))
    #expect(storage.writes == 1)
    // The read-back is what normalizes: the memo holds what storage actually kept,
    // not the string the caller passed in.
    #expect(store.current == "sk-new")
    #expect(storage.stored == "sk-new")
    // One read for the read-back; `current` is served from the refreshed memo.
    #expect(storage.reads == 1)
  }

  @Test("save replaces a memoized key rather than serving the stale one")
  func saveOverwritesAnEarlierMemo() {
    // The rotation case: read the old key (memoizing it), then save a new one. A
    // memo that survived the write would keep authenticating with the old key until
    // relaunch.
    let storage = FakeKeyStorage(stored: "sk-old")
    let store = makeStore(storage)
    #expect(store.current == "sk-old")

    #expect(store.save("sk-new"))
    #expect(store.current == "sk-new")
  }

  @Test("save(nil) clears the key and the memo together")
  func saveNilClears() {
    let storage = FakeKeyStorage(stored: "sk-123")
    let store = makeStore(storage)
    #expect(store.current == "sk-123")

    #expect(store.save(nil))
    #expect(store.current == nil)
    #expect(storage.stored == nil)
  }

  @Test("a blank save clears, matching the storage layer's empty-means-delete rule")
  func saveBlankClears() {
    let storage = FakeKeyStorage(stored: "sk-123")
    let store = makeStore(storage)
    #expect(store.save("   \n"))
    #expect(store.current == nil)
    #expect(storage.stored == nil)
  }

  @Test("a failed write reports false and leaves no key memoized")
  func failedWriteLeavesNothingMemoized() {
    let storage = FakeKeyStorage()
    storage.failWrites()
    let store = makeStore(storage)

    #expect(store.save("sk-123") == false)
    // Nothing was stored, so nothing may be reported as stored — claiming success
    // here is how `hasKey` came to disagree with the keychain.
    #expect(store.current == nil)
    #expect(storage.stored == nil)
  }

  @Test("a failed write does not clobber the key already in storage")
  func failedWriteKeepsTheExistingKey() {
    let storage = FakeKeyStorage(stored: "sk-good")
    storage.failWrites()
    let store = makeStore(storage)

    #expect(store.save("sk-bad") == false)
    // The read-back still finds the old key, so the memo holds it — a rejected
    // rotation must not log the user out of a working key.
    #expect(store.current == "sk-good")
    #expect(storage.stored == "sk-good")
  }

  @Test("an unreadable read-back leaves the memo unloaded, not wrong")
  func unreadableReadBackLeavesMemoUnloaded() {
    let storage = FakeKeyStorage()
    let store = makeStore(storage)
    // The write lands, but the read-back can't confirm it. Memoizing *anything*
    // here would be a guess; leaving the memo unloaded means the next read asks
    // storage again and gets the truth.
    storage.scriptReads([.unavailable(errSecInteractionNotAllowed)])

    #expect(store.save("sk-123"))
    #expect(storage.stored == "sk-123")
    #expect(store.current == "sk-123")
    // Two reads: the unreadable read-back, then the retry that `current` forced.
    #expect(storage.reads == 2)
  }

  // MARK: - atomicity

  @Test("concurrent saves leave the memo agreeing with storage")
  func concurrentSavesKeepMemoAndStorageInAgreement() async {
    // THE ATOMICITY REGRESSION. When the write and the memo update weren't under one
    // lock, two overlapping writers could interleave as write A, write B, memo B,
    // memo A — leaving `hasKey` true for a key storage no longer held, and a 401 the
    // user couldn't explain until relaunch.
    //
    // The assertion is interleaving-independent: whichever save lands last, the memo
    // must report exactly what storage holds. It cannot pass by luck of scheduling —
    // any torn write/memo pair fails it.
    let storage = FakeKeyStorage()
    let store = makeStore(storage)

    await withTaskGroup(of: Void.self) { group in
      for i in 0..<50 {
        group.addTask { _ = store.save(i.isMultiple(of: 2) ? "sk-even" : "sk-odd") }
      }
    }

    #expect(store.current == storage.stored)
    #expect(store.current != nil)
  }

  // MARK: - keychain wiring

  @Test("the keychain convenience init memoizes over the item it was given")
  func keychainInitWiresBothClosures() {
    // The init `APIKeyStore` actually constructs. Its whole body is two closure
    // wirings, and a swapped or dropped one is invisible to every test above (they
    // pass their own closures) — so this drives it against an isolated keychain
    // item, never the real `AssemblyAIAPIKey` one.
    let keychain = KeychainStore(
      service: "dev.alex.blurt.tests", account: "memo-\(UUID().uuidString)")
    defer { keychain.write(nil) }
    let store = MemoizedKeyStore(keychain: keychain)

    // Read side: the item's value has to reach the memo.
    #expect(keychain.write("sk-from-keychain"))
    #expect(store.current == "sk-from-keychain")

    // Write side: a save has to land in that same item, not just in the memo.
    #expect(store.save("sk-replaced"))
    #expect(keychain.read() == .value("sk-replaced"))
    #expect(store.current == "sk-replaced")
  }
}
