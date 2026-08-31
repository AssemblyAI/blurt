import SwiftUI

/// Blurt's brand colors, taken from the app design (the "Blurt hub" / "Blurt
/// setup" comps, 2026-08-31). Two greens, because one green can't serve both
/// kinds of chrome the app puts on screen:
///
/// - `green` (`#01762F`) is the wordmark green and the accent on **light**
///   surfaces — the main window, Settings, the setup form. It's dark enough to
///   read as text and as a filled button's label backdrop.
/// - `greenOnDark` (`#67AD82`) is the same brand hue lifted for **dark**
///   surfaces — the overlay pill (a fixed dark capsule) and the app icon's
///   wordmark. `#01762F` on the pill's `Color(white: 0.16)` is nearly invisible.
///
/// `accent` is the appearance-adaptive pick between them, and needs no
/// `.tint(_:)` at any call site: it resolves the app's accent color, which
/// `Assets.xcassets/AccentColor` defines (wired up by
/// `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` in `project.yml`) as these
/// same two greens, light and dark. That catalog entry — rather than a color
/// built here and handed to `.tint(_:)` — is what makes the accent reach the
/// chrome the app never draws itself: `.tint(_:)` is a SwiftUI environment
/// value, so it stops at the edge of the view tree, while the Settings
/// window's toolbar selection, focus rings, and text selection are AppKit
/// resolving `NSColor.controlAccentColor`, which reads only the app's
/// asset-catalog accent. The hexes are duplicated in the catalog because JSON
/// can't reference Swift; keep the two in step.
enum BlurtBrand {
  /// `#01762F` — the wordmark green. The accent on light chrome.
  nonisolated static let green = Color(red: 1 / 255, green: 118 / 255, blue: 47 / 255)

  /// `#67AD82` — the brand hue lifted for dark chrome (the overlay pill, and
  /// the wordmark on the app icon's near-black gradient).
  nonisolated static let greenOnDark = Color(red: 103 / 255, green: 173 / 255, blue: 130 / 255)

  /// The appearance-adaptive accent — `green` under Aqua, `greenOnDark` under
  /// Dark Aqua — resolved from the asset catalog rather than rebuilt here, so
  /// a view that names it and a control the system tints for us can't disagree.
  ///
  /// Spelled out as a name of its own instead of leaving call sites to write
  /// `Color.accentColor`, because at those call sites the color is a *brand*
  /// decision (the row glyphs, the granted checkmark) and reads as one here.
  nonisolated static let accent = Color.accentColor

  /// `#1D1B16` — the brand ink, and the overlay pill's body in every state.
  /// Fixed rather than appearance-adaptive: the pill floats over whatever app
  /// the user is dictating into, so it can't take its cue from the app's own
  /// appearance the way a window can.
  nonisolated static let ink = Color(red: 29 / 255, green: 27 / 255, blue: 22 / 255)

  /// `#E67F36` — the pill's error text. The design keeps the body ink in every
  /// state and lets this carry the alarm, rather than flashing a red capsule.
  nonisolated static let errorOrange = Color(red: 230 / 255, green: 127 / 255, blue: 54 / 255)

  /// The brand orb's fill: the full palette swept bottom-to-top, pale lavender
  /// through both greens, into the blue-violet and back out to white. Stops and
  /// offsets are the design's own (`App elements/Recording.svg`).
  ///
  /// `.bottom` to `.top` because the source gradient runs y=32 → y=8, i.e. up
  /// the orb — flipping the endpoints instead of reversing the stop list keeps
  /// the offsets readable against the file they came from.
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

  /// The ring drawn around the orb while the pill is waiting: brand green into
  /// white, corner to corner. Spun by `BrandOrb`, which is what turns a static
  /// two-stop gradient into a progress cue.
  nonisolated static let orbRingGradient = LinearGradient(
    colors: [green, .white], startPoint: .topLeading, endPoint: .bottomTrailing)
}
