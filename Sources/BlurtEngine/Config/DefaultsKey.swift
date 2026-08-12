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
/// `SigningIdentityMigration.lastSigningTeamDefaultsKey`, which records what the
/// TCC migration already did. Those also don't carry the `Blurt` prefix every case
/// here does, and `DefaultsKeyTests` pins that so the distinction stays visible.
///
/// Raw values are the on-disk contract: **renaming one silently abandons every
/// existing user's setting**, so change a case name freely and its raw value never.
enum DefaultsKey: String, CaseIterable {
  case triggerKeyCode = "BlurtTriggerKeyCode"
  case soundPack = "BlurtSoundPack"
  case keyTerms = "BlurtKeyTerms"
  case developerMode = "BlurtDeveloperMode"
  case enhancedTranscripts = "BlurtEnhancedTranscripts"
  /// `OverlayOriginStore` persists a point, so it owns two keys rather than one.
  case overlayCustomOriginX = "BlurtOverlayCustomOriginX"
  case overlayCustomOriginY = "BlurtOverlayCustomOriginY"
  case lastUpdateCheck = "BlurtLastUpdateCheck"
}
