import BlurtDesign
import CoreFoundation

/// The full keyboard's widths, the iPhone's own: ten letter caps across at
/// one width, the side keys taking what seven letters and their gaps leave,
/// the bottom row's 123 and globe at the width the iPhone gives them and
/// return two of those wide. The numbers were read off the system keyboard
/// on the iPhone 18 Pro (`Design/apple-geometry.json`, scripts/apple-geometry.sh)
/// and live in the tokens; this is the arithmetic between them, unit-tested,
/// so the views carry none of it.
nonisolated struct KeyGeometry: Equatable {
  private typealias Metrics = DesignTokens.Metrics

  /// The width inside the side margins — what a row of keys has.
  let rowWidth: CGFloat

  init(rowWidth: CGFloat) { self.rowWidth = rowWidth }

  /// From the keyboard's whole width, margins included.
  init(width: CGFloat) { self.init(rowWidth: width - 2 * Metrics.marginSide) }

  var gap: CGFloat { Metrics.keyGap }
  /// Ten keys and nine gaps across the row.
  var letterWidth: CGFloat { (rowWidth - 9 * gap) / 10 }
  /// Shift and delete stand a little further from the letters than letters
  /// stand from each other.
  var sideGap: CGFloat { Metrics.keySideGap }
  var sideWidth: CGFloat { (rowWidth - 7 * letterWidth - 6 * gap - 2 * sideGap) / 2 }
  /// On the symbol pages the third row holds five punctuation keys between
  /// shift's and delete's places, filling the same span seven letters do.
  var punctuationWidth: CGFloat { (rowWidth - 2 * sideWidth - 2 * sideGap - 4 * gap) / 5 }
  /// The widths measured at the reference width scale with the keyboard.
  private var scale: CGFloat { (rowWidth + 2 * Metrics.marginSide) / Metrics.keyReferenceWidth }
  /// 123 (or ABC), and the globe when there is one.
  var abcWidth: CGFloat { Metrics.keyAbcWidth402 * scale }
  /// Return: two 123 keys and a gap.
  var returnWidth: CGFloat { 2 * abcWidth + gap }
  /// Space takes what the bottom row leaves.
  func spaceWidth(globe: Bool) -> CGFloat {
    rowWidth - abcWidth - (globe ? abcWidth + gap : 0) - returnWidth - 2 * gap
  }
}
