import CoreGraphics
import Foundation

/// Persists the overlay pill's user-dragged origin. Same shape as
/// `TriggerKeyStore` / `SoundPackStore`, and registered in
/// `PersistedSettings.allDefaultsKeys`.
///
/// Owned by the engine rather than the AppKit controller for the reason the
/// roster exists: these two keys used to be private to `OverlayWindowController`,
/// so no reset sweep knew about them — a pill dragged during a UI-test run (or by
/// `reset-install.sh`'s "clean install" path) survived into later runs, which is
/// exactly the staleness `PersistedSettings` was created to prevent. The clamping
/// this value feeds is already engine-side in `OverlayPlacement`, so its
/// persistence belongs next to it.
public struct OverlayOriginStore {
  /// Public so the reset sweep and `@AppStorage`-style observers can name them.
  public static let xDefaultsKey = "BlurtOverlayCustomOriginX"
  public static let yDefaultsKey = "BlurtOverlayCustomOriginY"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The dragged origin, or `nil` when the pill has never been moved.
  ///
  /// Both components must be present: `double(forKey:)` reports 0 for a missing
  /// key, so a half-written pair would otherwise place the pill at an implied
  /// origin instead of falling back to the default placement.
  public var origin: CGPoint? {
    get {
      guard defaults.object(forKey: Self.xDefaultsKey) != nil,
        defaults.object(forKey: Self.yDefaultsKey) != nil
      else { return nil }
      return CGPoint(
        x: defaults.double(forKey: Self.xDefaultsKey),
        y: defaults.double(forKey: Self.yDefaultsKey))
    }
    nonmutating set {
      guard let newValue else {
        defaults.removeObject(forKey: Self.xDefaultsKey)
        defaults.removeObject(forKey: Self.yDefaultsKey)
        return
      }
      defaults.set(Double(newValue.x), forKey: Self.xDefaultsKey)
      defaults.set(Double(newValue.y), forKey: Self.yDefaultsKey)
    }
  }
}
