#if DEBUG
  import SwiftUI
  import UIKit

  /// A UIKit field, since `keyboardAppearance` and `autocorrectionType` are
  /// what decide which keyboard iOS shows: the appearance picks the face, and
  /// autocorrection brings the predictive bar up, which is the band the
  /// keyboard's voice row stands in for.
  struct ProbeField: UIViewRepresentable {
    let dark: Bool
    let text: String
    let sentences: Bool

    func makeUIView(context _: Context) -> UITextField {
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

    func updateUIView(_: UITextField, context _: Context) {
      // Nothing to update: the probe's field is configured once, at launch, and never re-rendered.
    }
  }
#endif
