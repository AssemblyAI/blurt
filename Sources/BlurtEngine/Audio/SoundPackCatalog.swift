/// A host's set of selectable cue voices: the picker's sections, the lookup
/// behind a persisted id, and which voice an unset setting means.
///
/// The engine ships **no** catalog. It used to — 192 generated voices, whose
/// `startFileName`/`stopFileName` named `.m4a` files that live in Blurt's app
/// bundle and nowhere in the package — so a third-party consumer got a full
/// picker in which every choice played silence. The voices and the audio are one
/// artifact (`scripts/generate-sounds.swift` writes both, and `check.sh` pins
/// that they agree), and that artifact belongs to whoever ships the bundle. Blurt
/// builds `SoundPackCatalog.blurt` in the app target; `CueSoundPlayer` resolves
/// the stems against `Bundle.main`.
///
/// A value rather than a set of statics on `SoundPack`, so nothing about "which
/// voices exist" is process-global: a host with two catalogs (a preview picker, a
/// test fixture) constructs two.
public struct SoundPackCatalog: Sendable {
  /// Distinct group names, in catalog order — the picker's sections. Deduped
  /// through a `Set` (`insert(_:).inserted` as the filter, matching
  /// `KeyTermsStore.parse`) rather than an array `contains` scan per element, and
  /// resolved once at construction: the picker reads it, then `voices(in:)` per
  /// group, on every settings render.
  public let groups: [String]

  /// The voice an unset (or unrecognized) setting resolves to. Internal for the
  /// same reason as `find(id:)`: hosts reach it through `fromPersisted`, and
  /// restating the default view-side is exactly what `SoundStepView` was
  /// corrected not to do.
  let defaultPack: SoundPack

  /// Backs `find(id:)`. Stored, not computed: `find` runs from a `Binding` getter
  /// on every settings render and from `CueSoundPlayer`'s pack load, and a
  /// computed version rebuilt the index and scanned it linearly each time.
  private let byID: [String: SoundPack]

  /// Backs `voices(in:)` so the picker's per-group read is a dictionary hit
  /// rather than a full-catalog filter per section.
  private let voicesByGroup: [String: [SoundPack]]

  /// Builds a catalog from `voices`, resolving `defaultVoiceID` to the voice an
  /// unset setting means — falling back to `SoundPack.none` when nothing in
  /// `voices` carries that id, so a typo silences the cues rather than trapping.
  ///
  /// `SoundPack.none` is added to the lookup **after** the voices, so a voice
  /// that (wrongly) claims the reserved id `none` loses to the silent pack rather
  /// than making "no sound" unselectable. `check.sh`'s catalog check flags that
  /// collision in this repo; the ordering is what keeps a host that has no such
  /// check from losing the silence choice.
  public init(voices: [SoundPack], defaultVoiceID: String) {
    var seenGroups = Set<String>()
    groups = voices.compactMap { voice -> String? in
      guard let group = voice.group, seenGroups.insert(group).inserted else { return nil }
      return group
    }

    var index: [String: SoundPack] = [:]
    var byGroup: [String: [SoundPack]] = [:]
    for voice in voices {
      index[voice.id] = voice
      guard let group = voice.group else { continue }
      byGroup[group, default: []].append(voice)
    }
    // Spelled `SoundPack.none`, never `.none`: the expected type here is
    // `SoundPack?`, where a leading-dot `.none` is `Optional.none` — i.e. it would
    // *remove* the silent pack rather than install it.
    index[SoundPack.none.id] = SoundPack.none
    byID = index
    voicesByGroup = byGroup

    defaultPack = index[defaultVoiceID] ?? SoundPack.none
  }

  /// The voices belonging to one group, in catalog order.
  public func voices(in group: String) -> [SoundPack] { voicesByGroup[group] ?? [] }

  /// Looks a voice up by its persisted `id`. Internal: hosts reach voices through
  /// `fromPersisted`, so exporting this would only trip periphery's
  /// redundant-public check.
  func find(id: String) -> SoundPack? { byID[id] }

  /// Decodes a persisted pack id, falling back to `defaultPack` when the id is
  /// unset or names no voice in this catalog. The single decode-with-default rule
  /// shared by `SoundPackStore` and the `@AppStorage` views that read the raw id
  /// directly (so they re-render live on a Settings change) — mirroring
  /// `TriggerKey.fromPersisted`.
  public func fromPersisted(_ id: String?) -> SoundPack {
    guard let id, let pack = find(id: id) else { return defaultPack }
    return pack
  }
}
