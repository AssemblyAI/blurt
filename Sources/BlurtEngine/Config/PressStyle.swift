import Synchronization

/// The style the trigger key that started a dictation asked for
/// (`TriggerKeyStyleStore`), held in memory for that one dictation, so a key's
/// style never moves the main window's sticky selection.
///
/// Two steps, because the two readers run at different moments: the request's
/// instruction is built at press, the Recent row's style name when the
/// transcript lands — and a trigger key can be pressed in between (refused,
/// since the last dictation is still transcribing). `request(_:)` records what
/// the newest press asked for; `instructions(from:)`, read once per request,
/// adopts it as the dictation's own; `styleName(from:)` names that one.
public final class PressStyle: Sendable {
  private struct State {
    var requested: String?
    var inFlight: String?
  }

  private let state = Mutex(State())

  public init() {}

  /// A press is starting with `styleID` (nil: the main window's selection).
  public func request(_ styleID: String?) {
    state.withLock { $0.requested = styleID }
  }

  /// The instructions to append for the request being built — the transcriber's
  /// `customStyle`. Makes the requested style this dictation's.
  public func instructions(from store: StyleProfileStore = StyleProfileStore()) -> String? {
    let id = state.withLock { current -> String? in
      current.inFlight = current.requested
      return current.inFlight
    }
    return store.profile(for: id)?.instructions.trimmedNonEmpty()
  }

  /// The custom style the in-flight dictation was made with, for its Recent
  /// row — the session's `styleNameProvider`. Nil with enhanced transcripts off
  /// (no rewrite, so no style applied) or under base styling. `enhanced` nil
  /// reads the store — optional because a public default can't reach it.
  public func styleName(
    from store: StyleProfileStore = StyleProfileStore(), enhanced: Bool? = nil
  ) -> String? {
    guard enhanced ?? EnhancedTranscriptsStore().isEnabled else { return nil }
    return store.profile(for: state.withLock { $0.inFlight })?.name
  }
}
