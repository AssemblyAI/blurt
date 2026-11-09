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
/// Where the line goes (DESIGN.md › The two processes: the line's place):
/// `voicebar/note-gap` under the element's box in the panel, which has the
/// room. The bar's row is the token's 44 pt around a 32 pt box, and the
/// keyboard's height is the layout's, so nothing can sit under the element
/// there without the keyboard growing: the line takes the row's bottom text
/// line instead, at `size/line`, and the row is handed the band above it —
/// the element draws in the band, so the grille's 28 pt sits clear of the
/// words rather than under them. The row keeps its identity either way (one
/// view, a height that changes): a finger on the mic as the line comes up
/// is never dropped by the row being rebuilt.
struct VoiceRowHost<Row: View>: View {
  var model: KeyboardModel
  let slot: VoiceSlot
  /// The slot's row height: what the row gets, less the line in the bar.
  let rowHeight: CGFloat
  /// The row, built for the height it has.
  @ViewBuilder let row: (CGFloat) -> Row
  @Environment(\.keyboardPalette) private var palette

  /// Whether the line takes the row's bottom text line (the bar) rather than
  /// sitting under the element's box (the panel).
  private var lineTakesBand: Bool { slot == .bar && model.statusLine != nil }

  var body: some View {
    ZStack {
      if model.termDraft != nil {
        TermField(model: model)
          .transition(.opacity)
      } else if !model.hasFullAccess {
        note
          .transition(.opacity)
      } else {
        let band = lineTakesBand ? rowHeight - VoiceBar.lineHeight : rowHeight
        row(band)
          .frame(height: band)
          // The panel: the line hangs under the row's own bottom edge, a gap
          // away, wherever the row sits in the room above the keys — moved
          // down by its own height and the gap from the edge it is aligned to
          // (an alignment guide written on a conditional view is not read).
          .overlay(alignment: .bottom) {
            if slot == .panel { line.offset(y: VoiceBar.lineHeight + DesignTokens.Metrics.voicebarNoteGap) }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slot == .bar ? .top : .center)
          // The bar: the row at the top of its 44 pt, the line on the bottom.
          .overlay(alignment: .bottom) {
            if slot == .bar { line }
          }
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
        .font(.system(size: DesignTokens.Typography.sizeLine))
        .foregroundStyle(palette.notice)
        .lineLimit(1)
        .minimumScaleFactor(0.8)  // literal-ok: the note may shrink a little on a narrow phone
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(KeyPressStyle())
    .accessibilityLabel("Start Blurt")
  }

  /// One line under the element, in the notice colour, or nothing: ready
  /// and idle is wordless, as Apple's keyboard is. One text line tall; in
  /// the bar the whole bottom band is the line's key, as the row above it
  /// is the mic's.
  @ViewBuilder private var line: some View {
    if let line = model.statusLine {
      Button {
        model.tapMic()
      } label: {
        Text(line.text)
          .font(.system(size: DesignTokens.Typography.sizeLine))
          .foregroundStyle(palette.notice)
          .lineLimit(1)
          .minimumScaleFactor(0.8)  // literal-ok: a long line may shrink a little on a narrow phone
          .frame(maxWidth: slot == .bar ? .infinity : nil)
      }
      .buttonStyle(KeyPressStyle())
      .accessibilityIdentifier("blurt-line")
      .frame(height: VoiceBar.lineHeight)
      .transition(.opacity)
    }
  }
}
