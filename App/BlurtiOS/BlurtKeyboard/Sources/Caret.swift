import BlurtDesign
import KeyboardKit
import SwiftUI

/// A blinking caret, as a text field's; held on under Reduce Motion.
struct Caret: View {
  var gap: Edge.Set
  @EnvironmentObject private var keyboardContext: KeyboardContext
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    TimelineView(.periodic(from: .now, by: DesignTokens.Motion.caret)) { timeline in
      let on =
        reduceMotion || Int(timeline.date.timeIntervalSinceReferenceDate / DesignTokens.Motion.caret).isMultiple(of: 2)
      RoundedRectangle(cornerRadius: DesignTokens.Metrics.caretRadius)
        .fill(BlurtTint.signal(keyboardContext.colorScheme))
        .frame(width: DesignTokens.Metrics.caretWidth, height: DesignTokens.Metrics.caretHeight)
        .opacity(on ? 1 : 0)
        .padding(gap, DesignTokens.Metrics.caretLead)
    }
    .accessibilityHidden(true)
  }
}
