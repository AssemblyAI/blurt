import SwiftUI

/// Where the mic key sits across the keyboard, for one hand: at the left
/// edge, in the middle (the default), or at the right edge. Left and right
/// are the phone's own sides — the side the thumb is on — whatever the
/// language reads in (Settings → Keyboard, under the layout; the keyboard
/// reads it on appearance).
nonisolated enum MicAlignment: String, CaseIterable, Codable, Sendable, Identifiable {
  case left
  case center
  case right

  var id: String { rawValue }

  var title: String {
    switch self {
    case .left: "Left alignment"
    case .center: "Default"
    case .right: "Right alignment"
    }
  }

  var summary: String {
    switch self {
    case .left: "The mic key at the left edge of the keyboard, under your thumb."
    case .center: "The mic key in the middle of the keyboard."
    case .right: "The mic key at the right edge of the keyboard, under your thumb."
    }
  }
}

extension MicAlignment {
  /// The side of the row, as SwiftUI counts sides: left is the leading edge
  /// in a left-to-right language and the trailing one in a right-to-left
  /// one, so the mic stays under the thumb the user chose either way.
  func alignment(in direction: LayoutDirection) -> Alignment {
    switch self {
    case .center: .center
    case .left: direction == .leftToRight ? .leading : .trailing
    case .right: direction == .leftToRight ? .trailing : .leading
    }
  }

  /// Whether the + goes before the mic in the row: at the trailing edge, so
  /// the mic is the thing at the edge and the + sits on its inner side.
  func plusLeads(in direction: LayoutDirection) -> Bool {
    alignment(in: direction) == .trailing
  }

  /// `-BlurtGalleryAlign left|center|right`, or nil when the arguments don't say.
  static func parse(_ arguments: [String]) -> MicAlignment? {
    guard let flag = arguments.firstIndex(of: "-BlurtGalleryAlign"), arguments.count > flag + 1 else { return nil }
    return MicAlignment(rawValue: arguments[flag + 1])
  }
}
