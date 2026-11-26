import Dispatch
import Synchronization

/// Reads the history once and writes it one list at a time, in the order asked.
/// Each write is an atomic rename, so two left to run side by side could finish
/// in either order, and an older list landing last resurrects a deleted entry or
/// drops a new one.
///
/// It also owns the one rule about the window before the saved history is read
/// in: until `open(_:saved:)`, a write would replace the file with only this
/// session's entries, so `save` writes nothing and `saveNow` merges the file in
/// first. Callers save whenever their history changes and needn't know the window.
public final class TranscriptWriter: Sendable {
  private let store: TranscriptStore
  private let queue = DispatchQueue(label: HostIdentity.current.queueLabel("TranscriptStore"))
  /// Whether `open(_:saved:)` has merged the saved history in.
  private let isOpen = Mutex(false)

  public init(store: TranscriptStore) {
    self.store = store
  }

  /// The saved history, read from disk — blocking, so call it off the main
  /// actor. Pass what it returns to `open(_:saved:)`.
  public func load() -> [SavedTranscript] {
    store.load()
  }

  /// `current` — the entries made before the read finished — with the `saved`
  /// ones merged in under them (`TranscriptStore.merging`). From here on every
  /// write is the whole history. Entries made meanwhile are in no file yet, so
  /// the merge is queued to be written; with none, the file already holds it.
  public func open(_ current: [SavedTranscript], saved: [SavedTranscript]) -> [SavedTranscript] {
    let merged = TranscriptStore.merging(current, saved: saved)
    isOpen.withLock { $0 = true }
    if !current.isEmpty { save(merged) }
    return merged
  }

  /// Queues `entries` to be written after every write already queued, and
  /// returns at once. Before `open(_:saved:)`, writes nothing: `open` writes
  /// what was made meanwhile.
  public func save(_ entries: [SavedTranscript]) {
    guard isOpen.withLock({ $0 }) else {
      return
    }
    queue.async { [store] in try? store.save(entries) }
  }

  /// Writes `entries` before returning, behind every write already queued, so
  /// this one lands last — the write made as the app quits. Before
  /// `open(_:saved:)`, the saved entries `entries` doesn't have are read and
  /// added first: a history not yet read in would otherwise be replaced.
  public func saveNow(_ entries: [SavedTranscript]) {
    let opened = isOpen.withLock { $0 }
    let written = opened ? entries : TranscriptStore.merging(entries, saved: store.load())
    queue.sync { [store] in try? store.save(written) }
  }
}
