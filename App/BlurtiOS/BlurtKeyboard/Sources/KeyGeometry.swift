import CoreFoundation

/// The full keyboard's widths, the iPhone's own: ten letter caps across at
/// one width, the side keys taking what seven letters and their gaps leave,
/// the bottom row's 123 and globe at the width the iPhone gives them and
/// return two of those wide. The numbers are the profile's
/// (`KeyboardProfile`: the glass set read off the system keyboard on the
/// iPhone 18 Pro, the classic set as W/10 cells with the caps inset inside
/// them — `Design/apple-geometry-*.json`, scripts/apple-geometry.sh) and live
/// in the tokens; this is the arithmetic between them, unit-tested, so the
/// views carry none of it.
nonisolated struct KeyGeometry: Equatable {
  /// The width inside the side margins — what a row of keys has.
  let rowWidth: CGFloat
  let profile: KeyboardProfile

  init(rowWidth: CGFloat, profile: KeyboardProfile) {
    self.rowWidth = rowWidth
    self.profile = profile
  }

  /// From the keyboard's whole width, margins included.
  init(width: CGFloat, profile: KeyboardProfile) {
    self.init(rowWidth: width - 2 * profile.marginSide, profile: profile)
  }

  var gap: CGFloat { profile.keyGap }
  /// Ten keys and nine gaps across the row. On the classic profile the
  /// margin is half a gap, so this is the W/10 cell less two insets.
  var letterWidth: CGFloat { (rowWidth - 9 * gap) / 10 }
  /// Shift and delete stand a little further from the letters than letters
  /// stand from each other.
  var sideGap: CGFloat { profile.sideGap }
  var sideWidth: CGFloat { (rowWidth - 7 * letterWidth - 6 * gap - 2 * sideGap) / 2 }
  /// On the symbol pages the third row holds five punctuation keys between
  /// shift's and delete's places, filling the same span seven letters do.
  var punctuationWidth: CGFloat { (rowWidth - 2 * sideWidth - 2 * sideGap - 4 * gap) / 5 }
  /// 123 (or ABC), and the globe when there is one.
  var abcWidth: CGFloat { profile.abcWidth(rowWidth: rowWidth) }
  /// Return: two 123 keys and a gap.
  var returnWidth: CGFloat { 2 * abcWidth + gap }
  /// Space takes what the bottom row leaves: beside 123, the globe (on a
  /// Touch ID phone) and return — on a Face ID phone the row is 123 · space ·
  /// return, and space is a globe and a gap wider.
  func spaceWidth(globe: Bool) -> CGFloat {
    rowWidth - abcWidth - (globe ? abcWidth + gap : 0) - returnWidth - 2 * gap
  }
}
