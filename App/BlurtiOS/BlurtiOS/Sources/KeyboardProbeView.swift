import BlurtDesign
import BlurtiOSCore

#if DEBUG
  import SwiftUI
  import UIKit

  /// `-BlurtProbeField light|dark`: a bare text field that takes the system
  /// keyboard on launch, so the `BlurtiOSProbe` UI test can read that
  /// keyboard's geometry off this simulator — the numbers
  /// `Design/apple-geometry-glass-402.json` records and the `key/*` tokens are pinned
  /// to (`scripts/apple-geometry.sh`, DESIGN.md › Apple's geometry). Debug
  /// builds only; the keyboard itself never runs here.
  struct KeyboardProbeView: View {
    let dark: Bool
    /// `-BlurtProbeText <word>`: the field starts with this in it, so a flow
    /// can highlight a word in any layout, letter keys or not.
    var text = ""
    /// `-BlurtProbeSentences`: the field capitalizes sentences, as Messages
    /// does, so a flow can watch the keys' case; the geometry probes keep the
    /// field's default of none, so Apple's keys are read at rest.
    var sentences = false

    var body: some View {
      VStack {
        ProbeField(dark: dark, text: text, sentences: sentences)
          .frame(height: DesignTokens.Metrics.keyMinWidth)
          .padding()
        // Puts the keyboard away without leaving the field, so a flow can
        // bring it back into the same host and see what a re-appearance
        // in a living extension keeps or loses.
        Button("Dismiss keyboard") {
          UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .accessibilityIdentifier("probe-dismiss")
        .foregroundStyle(dark ? Color.white : Color.black)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(dark ? Color.black : Color.white)
    }

    /// `-BlurtProbeField light|dark`: the face the field asks for, so the Blurt
    /// keyboard comes up that way for a capture of the real extension
    /// (`scripts/ios-keyboard-shot.sh`, `scripts/ios-keyboard-flows.sh`).
    static func parse(_ arguments: [String]) -> Self? {
      guard let flag = arguments.firstIndex(of: "-BlurtProbeField") else {
        return nil
      }
      let face = arguments.count > flag + 1 ? arguments[flag + 1] : "light"
      guard face == "light" || face == "dark" else {
        return nil
      }
      // `-BlurtProbeResetTerms`: an empty key-term list, so a flow that adds a
      // word finds it new on every run (the App Group outlives the test).
      if arguments.contains("-BlurtProbeResetTerms") { SharedStore.keyTerms = [] }
      var initialText = ""
      if let textFlag = arguments.firstIndex(of: "-BlurtProbeText"), arguments.count > textFlag + 1 {
        initialText = arguments[textFlag + 1]
      }
      return Self(
        dark: face == "dark", text: initialText, sentences: arguments.contains("-BlurtProbeSentences")
      )
    }
  }
#endif
