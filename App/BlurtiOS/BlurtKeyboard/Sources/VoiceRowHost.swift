import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// What sits where the mic is — one switch for the bar and the panel, so the
/// two can never disagree about it: the key-term field while a term is being
/// typed; the Full Access note as the key when the App Group is out of reach
/// (without it nothing else here can work, and the user has to be told
/// where to go); else the row itself, with the status line under the
/// element (`VoiceNotice`, through `KeyboardModel.statusLine`): why a tap
/// opens Blurt, the words still being made, the countdown, where the words
/// went. The line is a key too — a tap on it does what it says — through
/// the same path as a tap on the mic (`KeyboardModel.tapMic`), so the words
/// and the tap can never disagree.
///
/// Where the line goes: `voicebar/note-gap` under the element's box in the
/// panel, which has the room. The bar's row is the token's 44 pt around a
/// 32 pt box, and the keyboard's height is the layout's, so nothing can sit
/// under the element there without the keyboard growing: the line sits on
/// the row's bottom edge instead, over the band the element leaves below it.
struct VoiceRowHost<Row: View>: View {
  var model: KeyboardModel
  let slot: VoiceSlot
  @ViewBuilder let row: () -> Row
  @Environment(\.keyboardPalette) private var palette

  var body: some View {
    ZStack {
      if model.termDraft != nil {
        TermField(model: model)
          .transition(.opacity)
      } else if !model.hasFullAccess {
        note
          .transition(.opacity)
      } else {
        row()
          .overlay(alignment: slot == .panel ? .center : .bottom) { line }
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: DesignTokens.Motion.termSwap), value: model.termDraft == nil)
    .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: model.statusLine)
  }

  /// The note is the key: it fills the slot, and a tap opens the app's setup.
  private var note: some View {
    Button {
      model.tapMic()
    } label: {
      Text(model.statusLine?.text ?? VoiceNotice.Copy.fullAccess)
        .font(.footnote)
        .foregroundStyle(palette.notice)
        .lineLimit(1)
        .minimumScaleFactor(0.8)  // literal-ok: the note may shrink a little on a narrow phone
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(KeyPressStyle())
    .accessibilityLabel("Start Blurt")
  }

  /// One footnote under the element, in the notice colour, or nothing: ready
  /// and idle is wordless, as Apple's keyboard is.
  @ViewBuilder private var line: some View {
    if let line = model.statusLine {
      // The line's top a gap under the element's box: the guide moves its
      // centre down by half the box and the gap. The bar aligns to the
      // bottom instead, where this guide is not consulted.
      let drop = slot.box.height / 2 + DesignTokens.Metrics.voicebarNoteGap  // literal-ok: half the box
      Button {
        model.tapMic()
      } label: {
        Text(line.text)
          .font(.footnote)
          .foregroundStyle(palette.notice)
          .lineLimit(1)
          .minimumScaleFactor(0.8)  // literal-ok: a long line may shrink a little on a narrow phone
          .fixedSize(horizontal: false, vertical: true)
      }
      .buttonStyle(KeyPressStyle())
      .accessibilityIdentifier("blurt-line")
      .alignmentGuide(VerticalAlignment.center) { dimensions in dimensions[.top] - drop }
      .transition(.opacity)
    }
  }
}
