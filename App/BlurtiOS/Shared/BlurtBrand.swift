import SwiftUI

/// Blurt's brand, as the Mac app defines it (`App/Blurt/Blurt/Branding/BlurtBrand.swift`,
/// from the 2026-08-31 comps), plus the handful of shades the keyboard needs
/// for a surface the Mac never draws. Compiled into the app and the keyboard.
///
/// The values live in `Design/tokens.json` and arrive here through the
/// generated `DesignTokens`; these are the Mac's names for them, kept so the
/// call sites still read in the Mac's vocabulary. Add a colour to the tokens,
/// not here.
///
/// The keyboard's surface is fixed per theme, the way the Mac's overlay pill is
/// fixed: it floats over whatever app the user is typing in, so it cannot take
/// its cue from that app's appearance, and it must read the same on a white
/// Notes page and a black Messages thread. Everything on it therefore names
/// the raw shades — `greenOnDark`, `ink` — and never `accent`.
enum BlurtBrand {
  /// `#01762F` — the wordmark green, for light chrome.
  nonisolated static let green = DesignTokens.Brand.green700
  /// `#67AD82` — the brand hue lifted for dark chrome: the pill's text and
  /// meter, the ring, the wordmark on the icon.
  nonisolated static let greenOnDark = DesignTokens.Brand.green400
  /// `#1D1B16` — the brand ink: the pill's body in every state, and the
  /// keyboard's surface.
  nonisolated static let ink = DesignTokens.Brand.ink
  /// `#E67F36` — the error word. The body stays ink; the word carries the alarm.
  nonisolated static let errorOrange = DesignTokens.Brand.orange

  // MARK: Keyboard surface — the ink family, one and two steps up

  /// `#33302A` — an ordinary key on the ink surface.
  nonisolated static let key = DesignTokens.Brand.ink700
  /// `#26231E` — a modifier key (shift, delete, globe, return): a step darker
  /// than a letter, as the system keyboard does it. The Mac's dark card fill.
  nonisolated static let keyDark = DesignTokens.Brand.ink800
  /// `#F2EEE6` — key legends: a warm white, not a cold one, on the warm ink.
  nonisolated static let keyText = DesignTokens.Brand.warmWhite

  /// The orb's fill: the design's own stops (`App elements/Recording.svg`),
  /// swept bottom to top.
  nonisolated static let orbGradient = DesignTokens.Gradients.orb

  /// The ring round the orb: green into white, corner to corner; spun while
  /// something is happening.
  nonisolated static let orbRingGradient = DesignTokens.Gradients.orbRing
}
