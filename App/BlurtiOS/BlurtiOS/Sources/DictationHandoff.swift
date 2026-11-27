import BlurtEngine
import BlurtiOSCore
import Synchronization

/// What the coordinator shares with the session's seams, which the engine
/// calls from its own actor: the press waiting to be taken, the press the
/// dictation in flight took, the contact names, the words just delivered, and
/// the App Group the key terms are read from. One per coordinator, captured by
/// the seams it builds, so two coordinators — two tests running side by side —
/// never read each other's press.
nonisolated final class DictationHandoff: Sendable {
  /// Who pressed last and what their field held, until the session accepts
  /// the press (`claimPress`). A press the session refuses — one arriving while
  /// a dictation is still in flight — must not take over that dictation's words.
  let pendingPress = Mutex(DictationCoordinator.Press())
  /// The press that started the dictation in flight: its keyboard, for the
  /// words to go back to, and what that keyboard saw around the cursor, read
  /// by the engine's context seam — and cleared once used, so nothing from
  /// another app's field primes a later request.
  let claimedPress = Mutex(DictationCoordinator.Press())
  /// Contact names, parsed once per lexicon refresh rather than on the press.
  let lexiconNames = Mutex<[String]>([])
  /// The words the session just delivered, waiting to be counted. The stats are
  /// recorded on the main actor when the dictation's terminal phase renders —
  /// after its recording has been timed, and in the same place a reset runs —
  /// rather than on the session's actor, where neither ordering holds.
  let deliveredText = Mutex<String?>(nil)
  let store: SharedStore

  init(store: SharedStore) {
    self.store = store
  }

  /// The user's own key terms (from the App Group, where the keyboard adds
  /// them on the spot), then the contact names the keyboard read off the
  /// phone, deduplicated case-insensitively. `KeyTerms` fits the list
  /// to the request's caps (100 terms, 2048 bytes), first entries first, which
  /// is why the typed terms lead.
  func keyTerms() -> [String] {
    // Not through the comma-separated form: a contact called "Smith, John"
    // is one name, and the engine takes an array.
    KeyTermList.normalized(store.keyTerms + lexiconNames.withLock { $0 })
  }

  /// The session accepted a press: the last one asked for becomes the
  /// dictation's, and is no longer pending. Nil, as the frontmost app: there is
  /// none to paste into on the iPhone; the words go back to the keyboard.
  ///
  /// The stop's recipient is kept, not replaced: a quick release can be
  /// accepted (`handleCommand`) before the session gets here, and it already
  /// names where this dictation's words go. Nothing stale can be in it — it is
  /// cleared when the last dictation ended, before any new press is accepted.
  func claimPress() -> CapturedFocus? {
    let press = pendingPress.withLock { pending in
      defer { pending = DictationCoordinator.Press() }
      return pending
    }
    claimedPress.withLock { claimed in
      claimed.address = press.address
      claimed.context = press.context
    }
    return nil
  }

  /// What the keyboard saw around the cursor on the press in flight, once.
  func fieldContext() -> FocusedFieldContext {
    claimedPress.withLock { press in
      defer { press.context = .empty }
      return press.context
    }
  }
}
