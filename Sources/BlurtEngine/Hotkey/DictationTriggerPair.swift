/// The two lone-modifier keys that trigger dictation — one per `DictationMode`
/// — kept as a value type so the "the two keys must stay distinct" rule lives
/// in one tested place rather than being re-derived at each Settings picker.
///
/// A picker changing one key can collide with the other; `assigning` resolves
/// that by *swapping* rather than rejecting, so the user always ends up with two
/// working, different triggers instead of a silently dropped edit.
public struct DictationTriggerPair: Sendable, Equatable {
  /// The key that produces the verbatim transcript.
  public var raw: TriggerKey
  /// The key that produces the server-side cleanup rewrite.
  public var cleaned: TriggerKey

  public init(raw: TriggerKey, cleaned: TriggerKey) {
    self.raw = raw
    self.cleaned = cleaned
  }

  /// Returns a new pair with `mode`'s key set to `key`, preserving distinctness:
  /// if `key` collides with the other mode's key, the other mode takes this
  /// pair's current key for `mode` (a swap), so the two are never equal. Setting
  /// a mode to the key it already holds is a no-op.
  public func assigning(_ mode: DictationMode, to key: TriggerKey) -> DictationTriggerPair {
    switch mode {
    case .raw:
      // A collision hands `cleaned` the key `raw` is vacating — a swap — so the
      // pair stays distinct instead of both keys landing on `key`.
      let cleanedKey = key == cleaned ? raw : cleaned
      return DictationTriggerPair(raw: key, cleaned: cleanedKey)
    case .cleaned:
      let rawKey = key == raw ? cleaned : raw
      return DictationTriggerPair(raw: rawKey, cleaned: key)
    }
  }
}
