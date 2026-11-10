import BlurtiOSCore
import KeyboardKit
import SwiftUI

/// Apple's keyboard, drawn by KeyboardKit, with Blurt's two additions: the
/// mic key in the bottom row (`KeyboardLayout.blurt`, `MicKey`) and the bar
/// above the keys (`BlurtToolbar`). Every other key is KeyboardKit's standard
/// one, untouched. The mic wears the 123 key's style, the system key Apple's
/// own in-row mic sits on, so it reads as one of the row.
struct BlurtKeyboardView: View {
  var services: KeyboardServices
  var state: KeyboardState
  var model: BlurtiOSCore.KeyboardModel

  var body: some View {
    KeyboardView(
      layout: .blurt(for: state.keyboardContext),
      services: services,
      buttonContent: { params in
        if params.item.action == .blurtMic {
          MicKey(model: model)
        } else {
          params.view
        }
      },
      buttonView: { $0.view },
      collapsedView: { $0.view },
      emojiKeyboard: { $0.view },
      toolbar: { _ in BlurtToolbar(model: model) }
    )
    .keyboardButtonStyle { params in
      guard params.action == .blurtMic else { return params.standardStyle() }
      return Keyboard.ButtonStyleBuilderParams(
        action: .keyboardType(.numeric), context: params.context, isPressed: params.isPressed
      ).standardStyle()
    }
  }
}
