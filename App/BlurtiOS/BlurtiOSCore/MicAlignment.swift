import Foundation

/// Where the mic key sits across the keyboard, for one hand: at the left
/// edge, in the middle (the default), or at the right edge. Left and right
/// are the phone's own sides — the side the thumb is on — whatever the
/// language reads in (Settings → Keyboard, under the layout; the keyboard
/// reads it on appearance).
package nonisolated enum MicAlignment: String, CaseIterable, Codable, Sendable, Identifiable {
  case left
  case center
  case right

  package var id: String { rawValue }

  package var title: String {
    switch self {
    case .left: "Left alignment"
    case .center: "Default"
    case .right: "Right alignment"
    }
  }

  package var summary: String {
    switch self {
    case .left: "The mic key at the left edge of the keyboard, under your thumb."
    case .center: "The mic key in the middle of the keyboard."
    case .right: "The mic key at the right edge of the keyboard, under your thumb."
    }
  }
}

extension MicAlignment {
  /// `-BlurtGalleryAlign left|center|right`, or nil when the arguments don't say.
  package static func parse(_ arguments: [String]) -> MicAlignment? {
    guard let flag = arguments.firstIndex(of: "-BlurtGalleryAlign"), arguments.count > flag + 1 else { return nil }
    return MicAlignment(rawValue: arguments[flag + 1])
  }
}
