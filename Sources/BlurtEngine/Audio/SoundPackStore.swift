import Foundation

/// Persists the chosen `SoundPack` (by its `id`) in `UserDefaults`. Defaults to
/// `SoundPack.defaultPack` (HARP 1) when unset or when the stored id isn't a
/// known pack. Same shape as `TriggerKeyStore`.
public struct SoundPackStore {
  /// UserDefaults key holding the selected pack id. Public so SwiftUI views can
  /// observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static let defaultsKey = "BlurtSoundPack"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var soundPack: SoundPack {
    get {
      guard let id = defaults.string(forKey: Self.defaultsKey),
        let pack = SoundPack.find(id: id)
      else { return .defaultPack }
      return pack
    }
    nonmutating set {
      defaults.set(newValue.id, forKey: Self.defaultsKey)
    }
  }
}
