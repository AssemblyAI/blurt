// No `import Foundation`: this is a bare `String`-raw-value enum, so nothing here
// needs it, and `swiftlint analyze`'s unused_import rule fails the build on one.
// The stores that actually touch `UserDefaults` import it themselves.

/// Every `UserDefaults` key an engine settings store persists, defined once.
///
/// The stores don't spell their key as a string literal — each one's `defaultsKey`
/// reads a case from here — so the roster `PersistedSettings.resetAll` sweeps is
/// `allCases` rather than a hand-maintained list. That's the point: adding a store
/// means adding a case, and a case is in the sweep the moment it exists. The list
/// and the sweep can no longer disagree, which is what a copied-and-edited store
/// used to get wrong (the overlay origin and the update-check stamp were both
/// missed once, and a UI-test run inherited them).
///
/// A key that is *not* a user setting stays out of this enum on purpose — see
/// `SigningIdentityMigration.lastSigningIdentityDefaultsKey`, which records what the
/// TCC migration already did. Those also don't carry the host prefix every case
/// here does, and `DefaultsKeyTests` pins that so the distinction stays visible.
///
/// Raw values are the **unprefixed** half of the on-disk contract: the key actually
/// written is `key`, the host identity's `defaultsPrefix` followed by the raw value,
/// so Blurt still writes `BlurtSoundPack` and a host that configures its own prefix
/// gets its own namespace instead of writing into Blurt's. **Renaming a raw value
/// silently abandons every existing user's setting**, so change a case name freely
/// and its raw value never — and see `HostIdentity.defaultsPrefix` for why the
/// prefix carries the same warning.
enum DefaultsKey: String, CaseIterable {
  case triggerKeyCode = "TriggerKeyCode"
  case soundPack = "SoundPack"
  case keyTerms = "KeyTerms"
  case developerMode = "DeveloperMode"
  case enhancedTranscripts = "EnhancedTranscripts"
  case customStyle = "CustomStyle"
  /// `OverlayOriginStore` persists a point, so it owns two keys rather than one.
  case overlayCustomOriginX = "OverlayCustomOriginX"
  case overlayCustomOriginY = "OverlayCustomOriginY"
  case lastUpdateCheck = "LastUpdateCheck"

  /// The key this case actually reads and writes, under the configured host
  /// identity. A computed property rather than a stored string because the
  /// identity is only known once the host has configured it — and because it is
  /// then fixed for the process, so this resolves to the same value every time.
  var key: String { key(in: .current) }

  /// The key this case would write under `identity`. Split out so the tests can
  /// pin the composition against a value instead of the process-wide identity,
  /// which every other suite is reading concurrently.
  func key(in identity: HostIdentity) -> String { identity.defaultsKey(rawValue) }
}
