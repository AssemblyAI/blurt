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
  /// UserDefaults key holding the selected pack id. Public so SwiftUI views can
  /// observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.soundPack.key }

  private let catalog: SoundPackCatalog
  private let defaults: UserDefaults

  public init(catalog: SoundPackCatalog, defaults: UserDefaults = .standard) {
    self.catalog = catalog
    self.defaults = defaults
  }

  public var soundPack: SoundPack {
    get {
      catalog.fromPersisted(defaults.string(forKey: Self.defaultsKey))
    }
    nonmutating set {
      defaults.set(newValue.id, forKey: Self.defaultsKey)
    }
  }
}
