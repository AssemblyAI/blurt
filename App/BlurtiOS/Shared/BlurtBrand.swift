import SwiftUI

/// Blurt's brand, as the Mac app defines it (`App/Blurt/Blurt/Branding/BlurtBrand.swift`,
/// from the 2026-08-31 comps), plus the handful of shades the keyboard needs
/// for a surface the Mac never draws. Compiled into the app and the keyboard.
///
/// The keyboard's surface is fixed per theme, the way the Mac's overlay pill is
/// fixed: it floats over whatever app the user is typing in, so it cannot take
/// its cue from that app's appearance, and it must read the same on a white
/// Notes page and a black Messages thread. Everything on it therefore names
/// the raw shades — `greenOnDark`, `ink` — and never `accent`.
enum BlurtBrand {
  /// `#01762F` — the wordmark green, for light chrome.
  nonisolated static let green = Color(red: 1 / 255, green: 118 / 255, blue: 47 / 255)
  /// `#67AD82` — the brand hue lifted for dark chrome: the pill's text and
  /// meter, the ring, the wordmark on the icon.
  nonisolated static let greenOnDark = Color(red: 103 / 255, green: 173 / 255, blue: 130 / 255)
  /// `#1D1B16` — the brand ink: the pill's body in every state, and the
  /// keyboard's surface.
  nonisolated static let ink = Color(red: 29 / 255, green: 27 / 255, blue: 22 / 255)
  /// `#E67F36` — the error word. The body stays ink; the word carries the alarm.
  nonisolated static let errorOrange = Color(red: 230 / 255, green: 127 / 255, blue: 54 / 255)

  // MARK: Keyboard surface — the ink family, one and two steps up

  /// `#33302A` — an ordinary key on the ink surface.
  nonisolated static let key = Color(red: 51 / 255, green: 48 / 255, blue: 42 / 255)
  /// `#26231E` — a modifier key (shift, delete, globe, return): a step darker
  /// than a letter, as the system keyboard does it. The Mac's dark card fill.
  nonisolated static let keyDark = Color(red: 38 / 255, green: 35 / 255, blue: 30 / 255)
  /// `#F2EEE6` — key legends: a warm white, not a cold one, on the warm ink.
  nonisolated static let keyText = Color(red: 242 / 255, green: 238 / 255, blue: 230 / 255)

  /// The orb's fill: the design's own stops (`App elements/Recording.svg`),
  /// swept bottom to top.
  nonisolated static let orbGradient = LinearGradient(
    stops: [
      .init(color: Color(red: 215 / 255, green: 211 / 255, blue: 244 / 255), location: 0),
      .init(color: Color(red: 176 / 255, green: 167 / 255, blue: 233 / 255), location: 0.0673),
      .init(color: greenOnDark, location: 0.1442),
      .init(color: green, location: 0.3029),
      .init(color: Color(red: 57 / 255, green: 35 / 255, blue: 199 / 255), location: 0.5962),
      .init(color: Color(red: 136 / 255, green: 123 / 255, blue: 221 / 255), location: 0.75),
      .init(color: Color(red: 215 / 255, green: 211 / 255, blue: 244 / 255), location: 0.8942),
      .init(color: .white, location: 1),
    ],
    startPoint: .bottom,
    endPoint: .top)

  /// The ring round the orb: green into white, corner to corner; spun while
  /// something is happening.
  nonisolated static let orbRingGradient = LinearGradient(
    colors: [green, .white], startPoint: .topLeading, endPoint: .bottomTrailing)
}
