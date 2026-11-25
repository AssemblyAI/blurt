import SwiftUI
import UIKit

/// The type roles the app draws with, in the system's own faces — no font is
/// bundled. Each role keeps the design it stands for: mono for eyebrows and
/// CTAs; serif for the app's headlines; the default face for body text. Call
/// sites name the role, never a face, and set it with the `View` modifiers
/// below (`bodyFont`, `headingFont`, `monoFont`), which follow Dynamic Type:
/// each token size is the size at the default text size, scaled with the
/// user's setting along the text style the role stands nearest. The keyboard
/// takes nothing from here — its text is KeyboardKit's or its own, at fixed
/// sizes, as the system keyboard's is.
package enum BlurtType {
  /// Eyebrows and CTAs, at `size` exactly: for a size worked out from the
  /// space available (the stats card's fit), already chosen against the
  /// layout. Everywhere else, `monoFont`.
  package nonisolated static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }

  /// The app's headlines, sentence case, at `size` exactly (see `mono`).
  package nonisolated static func heading(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }

  /// The app's body text, at `size` exactly (see `mono`).
  package nonisolated static func body(_ size: CGFloat, bold: Bool = false) -> Font {
    .system(size: size, weight: bold ? .bold : .regular)
  }

  /// `size` scaled for the user's text size along `style`, outside a view
  /// (a UIKit text view's font). Pair with `adjustsFontForContentSizeCategory`.
  package static func scaledBody(_ size: CGFloat, relativeTo style: UIFont.TextStyle = .body) -> UIFont {
    UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size))
  }
}

extension View {
  /// The body face at `size` points, following Dynamic Type.
  package func bodyFont(_ size: CGFloat, bold: Bool = false) -> some View {
    modifier(ScaledFont(size: size, relativeTo: .body) { BlurtType.body($0, bold: bold) })
  }

  /// The headline face at `size` points, following Dynamic Type.
  package func headingFont(_ size: CGFloat) -> some View {
    modifier(ScaledFont(size: size, relativeTo: .title) { BlurtType.heading($0) })
  }

  /// The mono face at `size` points, following Dynamic Type.
  package func monoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
    modifier(ScaledFont(size: size, relativeTo: .footnote) { BlurtType.mono($0, weight: weight) })
  }
}

/// A role's font at a token size scaled by the user's text size: `@ScaledMetric`
/// re-reads the setting, so a change in Settings reaches the screen at once.
private struct ScaledFont: ViewModifier {
  @ScaledMetric private var size: CGFloat
  private let font: (CGFloat) -> Font

  init(size: CGFloat, relativeTo style: Font.TextStyle, font: @escaping (CGFloat) -> Font) {
    _size = ScaledMetric(wrappedValue: size, relativeTo: style)
    self.font = font
  }

  func body(content: Content) -> some View {
    content.font(font(size))
  }
}
