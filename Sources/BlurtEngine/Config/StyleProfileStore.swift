import Foundation

/// One named set of style instructions — free text (e.g. "add some emojis where
/// appropriate sparingly", "always write in lowercase") that the dictation API's
/// server-side rewrite applies on top of the base cleanup instruction (see
/// `CleanupInstruction.sendable(appending:)`).
///
/// The `id` is what the active-profile pointer and the main window's switcher
/// are keyed on, so it is assigned once at creation and never re-derived from
/// the name: renaming a profile must not silently deactivate it.
public struct StyleProfile: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public var name: String
  public var instructions: String

  /// A brand-new profile. The id is generated here rather than by the caller so
  /// there is one place that mints them.
  public init(name: String, instructions: String) {
    self.init(id: UUID(), name: name, instructions: instructions)
  }

  /// Full init, used by the decoder and by the migration's fixed-id profile.
  init(id: UUID, name: String, instructions: String) {
    self.id = id
    self.name = name
    self.instructions = instructions
  }
}

/// Storage for the user's style profiles and which one is active — possibly
/// none of them: the main window's switcher leads with a **Cleaned Up** segment
/// that selects the base styling, i.e. no profile instructions appended at all.
///
/// Optional: with no profiles the request is exactly what ships with no style
/// set at all. Inert while enhanced transcripts are off, since the `llm` block
/// the instruction rides on is omitted entirely. `AssemblyAITranscriber` reads
/// `activeInstructions` at each request, so an edit — or a click on the main
/// window's switcher — applies to the very next dictation.
///
/// **Only the active profile is ever sent.** Concatenating them would be the
/// obvious-looking generalization and is the one thing this must not do: the
/// API's 2048-byte instruction cap rejects the *whole request* when exceeded, so
/// a combined instruction fails every dictation rather than degrading. A
/// 3057-character instruction shipped that way once (see `CleanupInstruction`).
///
/// Unlike the single-field store it replaces, this one has setters. That is the
/// documented exception for a value that is *encoded* on write (as with
/// `TriggerKeyStore`'s keycode and `SoundPackStore`'s id): the JSON shape is the
/// store's business, so the views write through here and merely *observe* the
/// raw slots with `@AppStorage` — see `HotkeyStepView`, where binding the raw
/// slot directly left the setter test-only and a change to the encoding would
/// have kept `swift test` green while the UI wrote the old form.
///
/// **The legacy single field is read, never written.** An install that predates
/// profiles has text under `DefaultsKey.customStyle` and no list at all; that
/// reads back as one active profile named "Custom" holding it (see
/// `legacyProfiles`). The old key is left in place — a write-side migration
/// would have to run somewhere, and there is no launch hook that could not also
/// run before the user's defaults are readable, whereas a read-side fallback is
/// correct on every read and needs no ordering guarantee.
public struct StyleProfileStore {
  /// `UserDefaults` key holding the JSON-encoded profile list. Public so SwiftUI
  /// views can observe it directly (e.g. `@AppStorage`) and re-render on change.
  /// Stored as a `String` rather than `Data` for exactly that reason —
  /// `@AppStorage` observes a string slot, and JSON is text anyway.
  public static var defaultsKey: String { DefaultsKey.styleProfiles.key }

  /// `UserDefaults` key holding the active profile's id, as its `uuidString`.
  /// A second key rather than a field inside the list so switching the active
  /// style rewrites a 36-byte string instead of re-encoding every profile.
  public static var activeDefaultsKey: String { DefaultsKey.activeStyleProfile.key }

  /// The pre-profiles single style field, which this store still reads (see the
  /// migration note above) and never writes.
  static var legacyDefaultsKey: String { DefaultsKey.customStyle.key }

  /// What the active-id slot holds when the user has clicked **Cleaned Up**
  /// (this API keeps the internal name Default): base styling, no profile's
  /// instructions appended. A sentinel *distinct from unset* on purpose — an
  /// empty slot means "never chose", which resolves to the first profile (see
  /// `active(in:id:)`), and the two must not collapse: a legacy user's migrated
  /// "Custom" profile stays active through the upgrade precisely because their
  /// pointer is unset, and reading unset as the sentinel would silently switch
  /// their styling off. Not a UUID, so it can never collide with a real
  /// profile's id.
  public static let defaultStyleID = "default"

  /// How many profiles the user may define. With the leading Cleaned Up segment
  /// that is five, the most the main window's switcher can hold at a legible
  /// width; past that it would have to scroll or become a menu, which is a lot
  /// of chrome for a switch that is one click either way.
  public static let profileLimit = 4

  /// The most UTF-8 bytes one profile's instructions may hold —
  /// `CleanupInstruction.customStyleBudget`, the real headroom the dictation
  /// API's 2048 instruction cap leaves after the base instruction (see
  /// `CleanupInstruction.characterCap` for why the unit is bytes). Re-exported
  /// here (the editor's counter and the engine's trim have to agree) rather than
  /// restated, which is how the cap bug shipped once before. It is a *per
  /// profile* budget because only one profile is ever sent.
  public static let characterLimit = CleanupInstruction.customStyleBudget

  /// The most `Character`s a profile name may hold. Counted in characters, not
  /// the UTF-8 bytes `characterLimit` uses, because this limit exists for a
  /// different reason: the name labels a segment of the main window's switcher
  /// (and the shortcut readout under the keycap), so this is a layout bound
  /// rather than a wire one.
  public static let nameLimit = 24

  /// The name a profile falls back to when its own is blank. Reachable only from
  /// a hand-edited or corrupt defaults value — the editor won't save a nameless
  /// profile — but a segment with no label is not something to render.
  static let fallbackName = "Style"

  /// The name the migrated legacy field takes. "Custom" because that is what the
  /// single field it came from was called in Settings.
  static let legacyProfileName = "Custom"

  /// The id the migrated legacy profile carries. Fixed (the ASCII of
  /// "blurtstylelegacy") rather than freshly generated, so every read of an
  /// unmigrated install names the *same* profile — a new UUID per read would
  /// make the active pointer unmatchable and the segment identity flicker.
  /// Spelled as bytes because `UUID(uuidString:)` is optional and force-unwraps
  /// are banned repo-wide.
  static let legacyProfileID = UUID(
    uuid: (
      0x62, 0x6C, 0x75, 0x72, 0x74, 0x73, 0x74, 0x79, 0x6C, 0x65, 0x6C, 0x65, 0x67, 0x61, 0x63,
      0x79
    ))

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The user's profiles, in their own order. Normalized on the way out as well
  /// as in, so a hand-edited or truncated defaults value can't put an over-long
  /// instruction on the wire or a fifth profile on screen.
  public var profiles: [StyleProfile] {
    get { profiles(decoding: defaults.string(forKey: Self.defaultsKey) ?? "") }
    nonmutating set {
      // A list of strings cannot fail to encode, and `JSONEncoder` emits UTF-8
      // by definition, so neither step can realistically fail. Both are spelled
      // failably anyway: dropping the write beats trapping in a settings sheet,
      // and the non-failable `String(decoding:as:)` would quietly substitute
      // U+FFFD for a malformed byte instead of saying so.
      guard let data = try? JSONEncoder().encode(Self.normalized(newValue)),
        let json = String(data: data, encoding: .utf8)
      else { return }
      defaults.set(json, forKey: Self.defaultsKey)
    }
  }

  /// Makes `profile` the one the next dictation uses. **Sticky** — nothing
  /// resets it, so a style chosen once stays chosen until the user picks another
  /// or deletes it. A method rather than a settable `activeProfileID` because
  /// there is exactly one thing a caller ever wants to say here, and "unset it"
  /// is not it: the fallback in `active` already covers every way the pointer
  /// can stop naming a profile.
  public func activate(_ profile: StyleProfile) {
    defaults.set(profile.id.uuidString, forKey: Self.activeDefaultsKey)
  }

  /// Makes **Cleaned Up** — the base styling, no profile appended — the choice
  /// (the API keeps the internal name Default). As sticky as `activate(_:)`:
  /// it holds until another segment is selected.
  public func activateDefault() {
    defaults.set(Self.defaultStyleID, forKey: Self.activeDefaultsKey)
  }

  /// The profile the next request's instruction comes from — see
  /// `active(in:id:)`, which is the same resolution over the stored pointer.
  /// Internal: the app resolves the profiles it has already observed through
  /// that static instead, and periphery's redundant-public check would flag a
  /// `public` here that no host reaches.
  var active: StyleProfile? {
    Self.active(in: profiles, id: defaults.string(forKey: Self.activeDefaultsKey) ?? "")
  }

  /// The profiles behind a raw slot value a SwiftUI view has **already
  /// observed**, so the view can bind `@AppStorage` to `defaultsKey` — which is
  /// what re-renders it when a write lands — and still get the decode, the caps
  /// and the pre-profiles fallback from here rather than re-implementing them.
  /// The store's own getter is this same call over its own defaults, so the two
  /// cannot drift.
  ///
  /// An empty `raw` is "no list stored": `@AppStorage`'s default for a `String`
  /// slot is `""` and is indistinguishable from an absent key, so blank has to
  /// mean unset — which is safe, because a stored empty list is `"[]"`.
  public func profiles(decoding raw: String) -> [StyleProfile] {
    // Only "never had a list" defers to the legacy field. A stored value that
    // won't decode reads as no profiles rather than reviving the pre-profiles
    // text, which would be a surprising resurrection years later.
    guard !raw.isEmpty else { return Self.legacyProfiles(defaults) }
    guard let decoded = try? JSONDecoder().decode([StyleProfile].self, from: Data(raw.utf8)) else {
      return []
    }
    return Self.normalized(decoded)
  }

  /// Which of `profiles` a raw active-id slot selects. `defaultStyleID` — the
  /// user clicked **Cleaned Up** — selects none of them, deliberately. Otherwise
  /// it is the profile the slot names, or the first defined one when it names
  /// nothing (never set, or a profile since deleted): falling back rather than
  /// answering `nil` keeps a defined style in effect after its neighbour is
  /// deleted, means the first profile a user adds is active without a second
  /// write, and — load-bearing — keeps a migrated legacy profile active, since
  /// an upgrading user's pointer is unset. Static, and taking the raw string,
  /// for the same reason as `profiles(decoding:)` — the switcher observes that
  /// slot and resolves it through this.
  public static func active(in profiles: [StyleProfile], id raw: String) -> StyleProfile? {
    guard raw != defaultStyleID else { return nil }
    guard let id = UUID(uuidString: raw), let match = profiles.first(where: { $0.id == id })
    else { return profiles.first }
    return match
  }

  /// The instructions to append to the cleanup instruction, or `nil` when there
  /// is no profile, **Cleaned Up** is selected, or the active text is blank —
  /// all three must mean "send the base instruction untouched", not an empty
  /// suffix. **The active profile's text alone**, never a join of every
  /// profile; see the type's note on the cap.
  var activeInstructions: String? {
    active?.instructions.trimmedNonEmpty()
  }

  /// One active profile named "Custom" holding the pre-profiles single field, or
  /// nothing when that field is unset or blank. The read-side half of the
  /// migration described on the type.
  private static func legacyProfiles(_ defaults: UserDefaults) -> [StyleProfile] {
    guard let legacy = defaults.string(forKey: legacyDefaultsKey).trimmedNonEmpty() else {
      return []
    }
    return normalized([
      StyleProfile(id: legacyProfileID, name: legacyProfileName, instructions: legacy)
    ])
  }

  /// The one funnel every profile list passes through, on read and on write: at
  /// most `profileLimit` profiles, each with a trimmed non-blank name of at most
  /// `nameLimit` characters and instructions trimmed to `characterLimit` UTF-8
  /// bytes. Idempotent, so running it on both sides costs nothing but a walk.
  /// Static because it is a rule about a list, with no defaults in it.
  static func normalized(_ profiles: [StyleProfile]) -> [StyleProfile] {
    profiles.prefix(profileLimit).map { profile in
      StyleProfile(
        id: profile.id,
        name: String((profile.name.trimmedNonEmpty() ?? fallbackName).prefix(nameLimit)),
        // Whole graphemes, so an emoji at the boundary is dropped rather than
        // split into an invalid fragment (see `String.prefix(maxUTF8Bytes:)`).
        instructions: profile.instructions.prefix(maxUTF8Bytes: characterLimit))
    }
  }
}
