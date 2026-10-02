import BlurtiOSCore
import SwiftUI

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
}
