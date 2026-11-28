import SwiftUI

/// A label whose title wraps to its full height, its icon beside the first line.
///
/// A plain `Label` in a list row, or in a chip at a fixed width, could come out
/// a line short at the largest accessibility text sizes and cut off its last
/// words: the iPhone accessibility audit caught the consent sheet's "The text
/// just before your cursor" clipped that way at AX XXXL. Wrapping the title
/// inside a `Label` was not enough: at accessibility sizes a list row's `Label`
/// sets its icon inline with the title's first line, and the audit went on
/// reporting the title clipped wherever the row sat. So this lays the two out
/// itself, the title a text of its own at its full height. Use this for any
/// label whose title can wrap.
package struct WrappingLabelStyle: LabelStyle {
  package init() {
    // Nothing to configure: the style only changes how the title sizes.
  }

  package func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .firstTextBaseline) {
      configuration.icon
      configuration.title
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension LabelStyle where Self == WrappingLabelStyle {
  /// A label whose title wraps to its full height (`WrappingLabelStyle`).
  package static var wrapping: Self { Self() }
}
