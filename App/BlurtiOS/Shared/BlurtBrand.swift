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
  /// `#E67F36` — the error word. The body stays ink; the word carries the alarm.
  nonisolated static let errorOrange = DesignTokens.Brand.orange
}
