import BlurtDesign
import BlurtiOSCore
import KeyboardKit
import SwiftUI

/// The bar above the keys — where Apple's keyboard shows its predictions,
/// empty on KeyboardKit's free core — with Blurt's own in it: the key-term
/// field while a term is being typed; the Full Access note as the whole bar
/// when the App Group is out of reach (without it nothing else here can
/// work, and the user has to be told where to go); else the status line
/// (`VoiceNotice`, through `KeyboardModel.statusLine`: why a tap opens
/// Blurt, the words still being made, the countdown, where the words went)
/// and the + at the trailing end. The line is a key too — a tap on it does
/// what it says — through the same path as a tap on the mic
/// (`KeyboardModel.tapMic`), so the words and the tap can never disagree.
/// Ready and idle is wordless, as Apple's bar is before the first word.
struct BlurtToolbar: View {
  var model: BlurtiOSCore.KeyboardModel
  @EnvironmentObject private var keyboardContext: KeyboardContext

  var body: some View {
    let scheme = keyboardContext.colorScheme
    ZStack {
      if model.termDraft != nil {
        TermField(model: model)
          .transition(.opacity)
      } else if !model.hasFullAccess {
        note(scheme)
          .transition(.opacity)
      } else {
        HStack(spacing: 0) {
          line(scheme)
          Spacer(minLength: 0)
          AddTermKey(model: model)
        }
        .padding(.horizontal, DesignTokens.Metrics.addtermInset)
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: Keyboard.ToolbarStyle.standardHeight)
    .animation(.easeInOut(duration: DesignTokens.Motion.termSwap), value: model.termDraft == nil)
    .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: model.statusLine)
  }

  /// The note is the key: it fills the bar, and a tap opens the app's setup.
  private func note(_ scheme: ColorScheme) -> some View {
    Button {
      model.tapMic()
    } label: {
      Text(model.statusLine?.text ?? VoiceNotice.Copy.fullAccess)
        .font(.system(size: DesignTokens.Typography.sizeLine))
        .foregroundStyle(BlurtTint.notice(scheme))
        .lineLimit(1)
        .minimumScaleFactor(0.8)  // literal-ok: the note may shrink a little on a narrow phone
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(KeyPressStyle())
    .accessibilityLabel("Start Blurt")
  }

  /// One line in the notice colour, or nothing.
  @ViewBuilder private func line(_ scheme: ColorScheme) -> some View {
    if let line = model.statusLine {
      Button {
        model.tapMic()
      } label: {
        Text(line.text)
          .font(.system(size: DesignTokens.Typography.sizeLine))
          .foregroundStyle(BlurtTint.notice(scheme))
          .lineLimit(1)
          .minimumScaleFactor(0.8)  // literal-ok: a long line may shrink a little on a narrow phone
          .padding(.horizontal, DesignTokens.Metrics.termPad)
          .frame(maxHeight: .infinity)
      }
      .buttonStyle(KeyPressStyle())
      .accessibilityIdentifier("blurt-line")
      .transition(.opacity)
    }
  }
}
