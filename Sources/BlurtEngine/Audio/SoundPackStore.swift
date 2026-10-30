import Foundation

/// Persists the chosen `SoundPack` (by its `id`) in `UserDefaults`. Defaults to
/// the catalog's default voice when unset or when the stored id isn't one of its
/// voices. Same shape as `TriggerKeyStore`, plus the catalog — which the host
/// owns, since the engine ships no voices (see `SoundPackCatalog`).
///
/// The store stays in the engine even though the catalog left it, because its key
/// is a `DefaultsKey` case and that enum is the single roster
/// `PersistedSettings.resetAll` sweeps. Moving persistence host-side would have
/// stranded the sound setting outside every reset — the exact bug the roster was
/// created to prevent, twice.
public struct SoundPackStore {
  /// Which cues a store holds: dictation's, or read-aloud's — its own pair, so
  /// a read never sounds like a recording starting.
  public enum Cue: Sendable {
    case dictation, readAloud
  }

  /// UserDefaults key holding dictation's pack id. Public so SwiftUI views can
  /// observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.soundPack.key }
  /// Read-aloud's pack id, the same way.
  public static var readAloudDefaultsKey: String { DefaultsKey.readAloudSoundPack.key }

  private let catalog: SoundPackCatalog
  private let defaults: UserDefaults
  private let key: String

  /// `catalog` supplies the voices and what an unset setting means, so a
  /// read-aloud store is given a catalog defaulting to read-aloud's pack
  /// (`SoundPackCatalog.defaulting(to:)`).
  public init(catalog: SoundPackCatalog, cue: Cue = .dictation, defaults: UserDefaults = .standard) {
    self.catalog = catalog
    self.defaults = defaults
    self.key = cue == .dictation ? Self.defaultsKey : Self.readAloudDefaultsKey
  }

  public var soundPack: SoundPack {
    get {
      catalog.fromPersisted(defaults.string(forKey: key))
    }
    nonmutating set {
      defaults.set(newValue.id, forKey: key)
    }
  }
}
