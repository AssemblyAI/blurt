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

    /// `-BlurtProbeField light|dark`: the face the field asks for, so the Blurt
    /// keyboard comes up that way for a capture of the real extension
    /// (`scripts/ios-keyboard-shot.sh`, `scripts/ios-keyboard-flows.sh`).
    static func parse(_ arguments: [String]) -> KeyboardProbeView? {
      guard let flag = arguments.firstIndex(of: "-BlurtProbeField") else { return nil }
      let face = arguments.count > flag + 1 ? arguments[flag + 1] : "light"
      guard face == "light" || face == "dark" else { return nil }
      // `-BlurtProbeResetTerms`: an empty key-term list, so a flow that adds a
      // word finds it new on every run (the App Group outlives the test).
      if arguments.contains("-BlurtProbeResetTerms") { SharedStore.keyTerms = [] }
      var text = ""
      if let flag = arguments.firstIndex(of: "-BlurtProbeText"), arguments.count > flag + 1 {
        text = arguments[flag + 1]
      }
      return KeyboardProbeView(
        dark: face == "dark", text: text, sentences: arguments.contains("-BlurtProbeSentences"))
    }

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
  }

  /// A UIKit field, since `keyboardAppearance` and `autocorrectionType` are
  /// what decide which keyboard iOS shows: the appearance picks the face, and
  /// autocorrection brings the predictive bar up, which is the band the
  /// keyboard's voice row stands in for.
  private struct ProbeField: UIViewRepresentable {
    let dark: Bool
    let text: String
    let sentences: Bool

    func makeUIView(context: Context) -> UITextField {
      let field = UITextField()
      field.accessibilityIdentifier = "probe-field"
      field.text = text
      field.keyboardAppearance = dark ? .dark : .light
      field.autocorrectionType = .yes
      field.autocapitalizationType = sentences ? .sentences : .none
      field.borderStyle = .roundedRect
      field.placeholder = "probe"
      DispatchQueue.main.async { field.becomeFirstResponder() }
      return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {}
  }
#endif
