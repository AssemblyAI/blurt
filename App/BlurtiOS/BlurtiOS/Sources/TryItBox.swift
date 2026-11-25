import BlurtDesign
import SwiftUI

/// "Try it here": a text box on the home screen for trying the Blurt keyboard
/// without leaving the app. iOS offers no public way for an app to choose a
/// third-party keyboard for its own field, but it remembers the keyboard last
/// used in a field that names itself (`textInputContextIdentifier`), so after
/// the first switch with the globe key the box opens on Blurt every time. The
/// keyboard inserts at the cursor, so dictating mid-sentence lands there.
struct TryItBox: View {
  @State private var text = ""

  var body: some View {
    RememberingTextView(text: $text)
      .frame(minHeight: DesignTokens.Metrics.appTryBoxHeight, alignment: .topLeading)
      .overlay(alignment: .topLeading) {
        if text.isEmpty {
          Text("Try it here")
            .font(BlurtType.body(DesignTokens.Typography.sizeBody))
            .foregroundStyle(BlurtBrand.muted)
            .allowsHitTesting(false)
        }
      }
      .brandInput()
  }
}
