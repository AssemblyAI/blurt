#if DEBUG
  import SwiftUI
  import UIKit

  /// `-BlurtProbeField light|dark`: a bare text field that takes the system
  /// keyboard on launch, so the `BlurtiOSProbe` UI test can read that
  /// keyboard's geometry off this simulator — the numbers
  /// `Design/apple-geometry.json` records and the `key/*` tokens are pinned
  /// to (`scripts/apple-geometry.sh`, DESIGN.md › Apple's geometry). Debug
  /// builds only; the keyboard itself never runs here.
  struct KeyboardProbeView: View {
    let dark: Bool

    /// `-BlurtProbeField light|dark [a|b|c] [slimBar|panel|full] [left|center|right]`:
    /// the words after the face set the mic concept, the layout and the mic's
    /// side in the App Group, so the Blurt keyboard — which reads them on every
    /// appearance — comes up that way for a capture of the real extension
    /// (`scripts/ios-keyboard-shot.sh`, `scripts/ios-keyboard-flows.sh`).
    static func parse(_ arguments: [String]) -> KeyboardProbeView? {
      guard let flag = arguments.firstIndex(of: "-BlurtProbeField") else { return nil }
      let face = arguments.count > flag + 1 ? arguments[flag + 1] : "light"
      guard face == "light" || face == "dark" else { return nil }
      // The mic's side is the middle unless a word says otherwise: the App
      // Group outlives a run, and an earlier `left` must not leak into this one.
      SharedStore.micAlignment = .center
      for word in arguments.dropFirst(flag + 2).prefix(while: { !$0.hasPrefix("-") }) {
        if let kind = VoiceElementKind(rawValue: word) { SharedStore.voiceElementKind = kind }
        if let layout = KeyboardLayout(rawValue: word) { SharedStore.layout = layout }
        if let side = MicAlignment(rawValue: word) { SharedStore.micAlignment = side }
      }
      // `-BlurtProbeResetTerms`: an empty key-term list, so a flow that adds a
      // word finds it new on every run (the App Group outlives the test).
      if arguments.contains("-BlurtProbeResetTerms") { SharedStore.keyTerms = [] }
      return KeyboardProbeView(dark: face == "dark")
    }

    var body: some View {
      VStack {
        ProbeField(dark: dark)
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

    func makeUIView(context: Context) -> UITextField {
      let field = UITextField()
      field.accessibilityIdentifier = "probe-field"
      field.keyboardAppearance = dark ? .dark : .light
      field.autocorrectionType = .yes
      field.autocapitalizationType = .none
      field.borderStyle = .roundedRect
      field.placeholder = "probe"
      DispatchQueue.main.async { field.becomeFirstResponder() }
      return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {}
  }
#endif
