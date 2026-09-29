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

    static func parse(_ arguments: [String]) -> KeyboardProbeView? {
      guard let flag = arguments.firstIndex(of: "-BlurtProbeField") else { return nil }
      let face = arguments.count > flag + 1 ? arguments[flag + 1] : "light"
      guard face == "light" || face == "dark" else { return nil }
      return KeyboardProbeView(dark: face == "dark")
    }

    var body: some View {
      VStack {
        ProbeField(dark: dark)
          .frame(height: DesignTokens.Metrics.keyMinWidth)
          .padding()
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
