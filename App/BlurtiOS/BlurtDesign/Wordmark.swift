import SwiftUI
import UIKit

/// The lowercase wordmark from the Mac's ready screen, tinted with the accent
/// unless told otherwise. The image (`blurt-ready-logo.png`, shared from
/// `Design/brand`) is the host bundle's resource, not the library's; without
/// it the word is set in the heading face instead.
package struct Wordmark: View {
  /// The image's width over its height, for a caller that has to know the
  /// wordmark's size before it is drawn (the Blurt-is-on card's bounce).
  package static var aspectRatio: CGFloat {
    // By name, not an asset symbol or literal: the image is the host bundle's loose PNG, which
    // this library has no generated symbol for, and its absence is a case handled below.
    // swiftlint:disable:next object_literal prefer_asset_symbols
    guard let size = UIImage(named: "blurt-ready-logo")?.size, size.height > 0 else {
      return 1
    }
    return size.width / size.height
  }

  private let height: CGFloat
  private let tint: Color

  package var body: some View {
    // swiftlint:disable:next object_literal prefer_asset_symbols
    if let image = UIImage(named: "blurt-ready-logo") {
      Image(uiImage: image)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(height: height)
        .foregroundStyle(tint)
        .accessibilityLabel("Blurt")
    } else {
      Text("blurt")
        .font(BlurtType.heading(DesignTokens.Typography.sizeTitle))
        .foregroundStyle(tint)
    }
  }

  package init(height: CGFloat = DesignTokens.Metrics.wordmarkHeight, tint: Color = BlurtBrand.accent) {
    self.height = height
    self.tint = tint
  }
}
