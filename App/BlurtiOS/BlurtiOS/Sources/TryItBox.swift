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
    // The text view itself takes the box's least height, not just its frame:
    // the whole box is what a tap lands on, and what VoiceOver outlines.
    RememberingTextView(text: $text, minHeight: DesignTokens.Metrics.appTryBoxHeight)
      .overlay(alignment: .topLeading) {
        if text.isEmpty {
          Text("Try it here")
            .bodyFont(DesignTokens.Typography.sizeBody)
            .foregroundStyle(BlurtBrand.muted)
            .allowsHitTesting(false)
            // The text view carries the same words as its label.
            .accessibilityHidden(true)
        }
      }
      .brandInput()
  }
}
