import SwiftUI

/// The type roles the app and the keyboard draw with, in the system's own
/// faces — no font is bundled. Each role keeps the design it stands for: mono
/// for eyebrows, CTAs and the keyboard's word labels; serif for the app's
/// headlines; the default face for body text. Call sites name the role, never
/// a face. Fixed point sizes throughout, as the system keyboard's are — no
/// Dynamic Type.
enum BlurtType {
  enum MonoWeight {
    case light
    case regular
    case medium
  }

  /// Eyebrows, CTAs, the keyboard's word labels.
  nonisolated static func mono(_ size: CGFloat, weight: MonoWeight = .regular) -> Font {
    .system(size: size, weight: fontWeight(weight), design: .monospaced)
  }

  /// The app's headlines, sentence case.
  nonisolated static func heading(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }

  /// The app's body text.
  nonisolated static func body(_ size: CGFloat, bold: Bool = false) -> Font {
    .system(size: size, weight: bold ? .bold : .regular)
  }

  private nonisolated static func fontWeight(_ weight: MonoWeight) -> Font.Weight {
    switch weight {
    case .light: .light
    case .regular: .regular
    case .medium: .medium
    }
  }
}
