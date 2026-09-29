import BlurtEngine
import SwiftUI

/// The keyboard's voice row, and the only place voice lives: the orb, which
/// is the mic key — tap to start and stop, hold to talk — dissipating into
/// the wave while recording. No words: the orb's ring and colour, or the
/// wave, say what is happening, and the haptics confirm it (see `MicKey`).
/// Beside it, a small
/// + for the one thing people want the instant Blurt mishears a word: add it
/// as a key term. The bar then becomes the field the keys type into.
struct VoiceBar: View {
  var model: KeyboardModel

  static let height = DesignTokens.Metrics.voicebarHeight

  var body: some View {
    GeometryReader { geo in
      ZStack {
        if model.termDraft != nil {
          TermField(model: model)
            .transition(.opacity)
        } else if !model.hasFullAccess {
          // The one state the orb can't show on its own: without Full Access
          // nothing here can work, and the user has to be told where to go.
          HStack(spacing: DesignTokens.Metrics.voicebarNoteGap) {
            MicKey(model: model, size: DesignTokens.Metrics.orbBar, wave: nil)
            Text("Allow Full Access in Settings → Keyboards")
              .font(.footnote)
              .foregroundStyle(BlurtBrand.errorOrange)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
          .transition(.opacity)
        } else {
          // The wave stays clear of the + at the trailing edge, on both sides so it stays centred.
          let clearance = DesignTokens.Metrics.glyphHit + DesignTokens.Metrics.voicebarAddtermClearance
          MicKey(
            model: model, size: DesignTokens.Metrics.orbBar,
            wave: CGSize(
              width: min(DesignTokens.Metrics.waveBarWidth, geo.size.width - 2 * clearance),  // literal-ok: both sides
              height: DesignTokens.Metrics.waveBarHeight)
          )
          .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(height: Self.height)
    .overlay(alignment: .trailing) {
      if model.termDraft == nil, model.hasFullAccess { AddTermKey(model: model) }
    }
    .animation(.easeInOut(duration: DesignTokens.Motion.termSwap), value: model.termDraft == nil)
  }
}

/// The small + beside the orb (and in the panel's corner): a new key term.
/// A bare glyph, quiet until it is needed; a check for a moment after one
/// was saved.
struct AddTermKey: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette

  var body: some View {
    Button {
      model.beginAddingTerm()
    } label: {
      Image(systemName: model.termSavedAt == nil ? "plus" : "checkmark")
        .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
        .foregroundStyle(
          model.termSavedAt == nil ? palette.keyText.opacity(DesignTokens.Metrics.opacityLegendMuted) : palette.signal
        )
        .frame(width: DesignTokens.Metrics.glyphHit, height: DesignTokens.Metrics.glyphHit)
        .contentShape(Circle())
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(KeyPressStyle())
    .accessibilityLabel("Add a key term")
    .disabled(!model.hasFullAccess)
    .opacity(model.hasFullAccess ? 1 : DesignTokens.Metrics.opacityDisabled)
  }
}

/// The voice bar as a field: × to leave, what has been typed with a caret,
/// ✓ to save. Return saves too.
private struct TermField: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette

  var body: some View {
    HStack(spacing: DesignTokens.Metrics.termGap) {
      round("xmark", tint: palette.keyText.opacity(DesignTokens.Metrics.opacityTermCancel)) { model.cancelAddingTerm() }
        .accessibilityLabel("Cancel")
      HStack(spacing: 0) {
        if let draft = model.termDraft, !draft.isEmpty {
          Text(draft).foregroundStyle(palette.keyText)
        } else {
          Text("New key term").foregroundStyle(palette.keyText.opacity(DesignTokens.Metrics.opacityPlaceholder))
        }
        Caret()
        Spacer(minLength: 0)
      }
      .font(.system(size: DesignTokens.Typography.sizeTerm, weight: DesignTokens.Typography.weightTerm))
      .lineLimit(1)
      .padding(.horizontal, DesignTokens.Metrics.termPad)
      .frame(maxWidth: .infinity)
      .frame(height: DesignTokens.Metrics.termHeight)
      .background(Capsule().fill(palette.keyDark))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Key term: \(model.termDraft ?? "")")
      round("checkmark", tint: palette.signal) { model.saveTerm() }
        .accessibilityLabel("Save the key term")
        .disabled(model.termDraft?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }
    .padding(.horizontal, DesignTokens.Metrics.termInset)
  }

  /// × and ✓: bare glyphs, as the + is.
  private func round(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
        .foregroundStyle(tint)
        .frame(width: DesignTokens.Metrics.glyphHit, height: DesignTokens.Metrics.glyphHit)
        .contentShape(Circle())
    }
    .buttonStyle(KeyPressStyle())
  }
}

/// A blinking caret, as a text field's; held on while motion is held.
private struct Caret: View {
  @Environment(\.keyboardPalette) private var palette
  @Environment(\.keyboardMotionHeld) private var motionHeld

  var body: some View {
    TimelineView(.periodic(from: .now, by: DesignTokens.Motion.caret)) { timeline in
      let on = motionHeld || Int(timeline.date.timeIntervalSinceReferenceDate / DesignTokens.Motion.caret) % 2 == 0
      RoundedRectangle(cornerRadius: DesignTokens.Metrics.caretRadius)
        .fill(palette.signal)
        .frame(width: DesignTokens.Metrics.caretWidth, height: DesignTokens.Metrics.caretHeight)
        .opacity(on ? 1 : 0)
        .padding(.leading, DesignTokens.Metrics.caretLead)
    }
    .accessibilityHidden(true)
  }
}

/// The Mac pill's live meter: a row of bars that fills the width it is given
/// and tracks the current level, with the engine's envelope and idle wave
/// (`MeterBarGeometry`, unit-tested there). The keyboard hears the level from
/// the app at ~12 Hz; the wave keeps the row alive between ticks. The pitch
/// is the Mac's unless the caller sets its own: the keyboard's wave is thin —
/// `slimBar` wide, `slimGap` apart — and dense, a fine signal rather than a
/// bank of bars.
struct WaveformMeter: View {
  let level: Float
  let animated: Bool
  let color: Color
  var barWidth: CGFloat = MeterBarGeometry.barWidth
  var barSpacing: CGFloat = MeterBarGeometry.barSpacing

  /// The keyboard's pitch: 2 pt bars, 2 pt apart.
  static let slimBar = DesignTokens.Metrics.waveBar
  static let slimGap = DesignTokens.Metrics.waveGap

  var body: some View {
    GeometryReader { geo in
      let count = Int((geo.size.width + barSpacing) / (barWidth + barSpacing))
      let layout = MeterBarRow(count: count, availableHeight: geo.size.height)
      Group {
        if animated {
          TimelineView(.animation(minimumInterval: keyboardAnimationInterval)) { timeline in
            bars(layout: layout, time: timeline.date.timeIntervalSinceReferenceDate)
          }
        } else {
          bars(layout: layout, time: 0)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .accessibilityHidden(true)
  }

  private func bars(layout: MeterBarRow, time: TimeInterval) -> some View {
    HStack(spacing: barSpacing) {
      ForEach(0..<layout.count, id: \.self) { index in
        Capsule()
          .fill(color)
          .frame(width: barWidth, height: layout.height(at: index, level: level, time: time, animated: animated))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
