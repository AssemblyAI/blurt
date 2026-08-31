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
}
