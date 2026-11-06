import Foundation

/// Persists each trigger key's own start/stop cue voice, as set in the Sounds
/// tab: keycode → `SoundPack.id`, one JSON object (`TriggerKeyMap`).
///
/// Ids only — the voices are the host's (`SoundPackCatalog`), so the host
/// decodes an entry against its catalog, and resolves a key with no entry from
/// its action's own cue setting (`SoundPackStore`). That fallback is why an
/// untouched install sounds exactly as it did before keys had sounds of their
/// own.
public struct TriggerKeySoundStore {
  /// Public so SwiftUI views can observe it directly (e.g. `@AppStorage`).
  public static var defaultsKey: String { DefaultsKey.triggerKeySounds.key }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Every key's stored pack id, from a raw slot value a view has observed.
  public static func soundIDs(decoding raw: String) -> [TriggerKey: String] {
    TriggerKeyMap.decode(raw)
  }

  /// `key`'s stored pack id, or nil when it follows its action's setting.
  public func soundID(for key: TriggerKey) -> String? {
    Self.soundIDs(decoding: defaults.string(forKey: Self.defaultsKey) ?? "")[key]
  }

  /// Sets `key`'s pack id; nil removes the entry, so it follows its action's
  /// setting again.
  public func setSoundID(_ id: String?, for key: TriggerKey) {
    var entries = Self.soundIDs(decoding: defaults.string(forKey: Self.defaultsKey) ?? "")
    entries[key] = id
    TriggerKeyMap.write(entries, to: Self.defaultsKey, in: defaults)
  }
}
