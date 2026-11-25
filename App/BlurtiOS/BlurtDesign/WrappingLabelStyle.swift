import SwiftUI

/// A label whose title wraps to its full height, beside its icon as usual.
///
/// A plain `Label` in a list row, or in a chip at a fixed width, could come out
/// a line short at the largest accessibility text sizes and cut off its last
/// words: the iPhone accessibility audit caught the consent sheet's "The text
/// just before your cursor" clipped that way at AX XXXL. Use this for any label
/// whose title can wrap.
package struct WrappingLabelStyle: LabelStyle {
  package init() {
    // Nothing to configure: the style only changes how the title sizes.
  }

  package func makeBody(configuration: Configuration) -> some View {
    Label {
      configuration.title
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      configuration.icon
    }
  }
}

extension LabelStyle where Self == WrappingLabelStyle {
  /// A label whose title wraps to its full height (`WrappingLabelStyle`).
  package static var wrapping: Self { Self() }
}
