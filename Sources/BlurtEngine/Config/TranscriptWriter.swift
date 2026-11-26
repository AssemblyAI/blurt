import Dispatch

/// Writes the history one list at a time, in the order asked. Each write is an
/// atomic rename, so two left to run side by side could finish in either order,
/// and an older list landing last resurrects a deleted entry or drops a new one.
public final class TranscriptWriter: Sendable {
  private let store: TranscriptStore
  private let queue = DispatchQueue(label: HostIdentity.current.queueLabel("TranscriptStore"))

  public init(store: TranscriptStore) {
    self.store = store
  }

  /// Queues `entries` to be written after every write already queued, and
  /// returns at once.
  public func save(_ entries: [SavedTranscript]) {
    queue.async { [store] in try? store.save(entries) }
  }

  /// Writes `entries` before returning, behind every write already queued, so
  /// this one lands last — the write made as the app quits. `mergingSaved`
  /// first adds the saved entries `entries` doesn't have: a history not yet
  /// read in would otherwise be replaced by only this session's entries.
  public func saveNow(_ entries: [SavedTranscript], mergingSaved: Bool) {
    let written = mergingSaved ? TranscriptStore.merging(entries, saved: store.load()) : entries
    queue.sync { [store] in try? store.save(written) }
  }
}
