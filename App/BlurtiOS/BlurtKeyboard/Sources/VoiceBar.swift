import BlurtEngine
import SwiftUI

/// The keyboard's voice row, and the only place voice lives: the orb, which
/// is the mic key — tap to start and stop, hold to talk — growing into the
/// wave while recording. No words: the orb's ring, shape and glow say what is
/// happening, and the haptics confirm it (see `MicKey`). Beside it, a small
/// + for the one thing people want the instant Blurt mishears a word: add it
/// as a key term. The bar then becomes the field the keys type into.
struct VoiceBar: View {
  var model: KeyboardModel

  static let height: CGFloat = 44

  var body: some View {
    ZStack {
      if model.termDraft != nil {
        TermField(model: model)
          .transition(.opacity)
      } else {
        MicKey(model: model, size: 40, expandedWidth: 200)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: Self.height)
    .overlay(alignment: .trailing) {
      if model.termDraft == nil { AddTermKey(model: model) }
    }
    .animation(.easeInOut(duration: 0.15), value: model.termDraft == nil)
  }
}

/// The small + beside the orb (and in the panel's corner): a new key term.
/// Shows a check for a moment after one was saved.
struct AddTermKey: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette

  var body: some View {
    Button {
      model.beginAddingTerm()
    } label: {
      Image(systemName: model.termSavedAt == nil ? "plus" : "checkmark")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(model.termSavedAt == nil ? palette.keyText.opacity(0.7) : BlurtBrand.greenOnDark)
        .frame(width: 32, height: 32)
        .background(Circle().fill(palette.keyDark))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(KeyPressStyle())
    .accessibilityLabel("Add a key term")
    .disabled(!model.hasFullAccess)
    .opacity(model.hasFullAccess ? 1 : 0.4)
  }
}

/// The voice bar as a field: × to leave, what has been typed with a caret,
/// ✓ to save. Return saves too.
private struct TermField: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette

  var body: some View {
    HStack(spacing: 8) {
      round("xmark", tint: palette.keyText.opacity(0.7)) { model.cancelAddingTerm() }
        .accessibilityLabel("Cancel")
      HStack(spacing: 0) {
        if let draft = model.termDraft, !draft.isEmpty {
          Text(draft).foregroundStyle(palette.keyText)
        } else {
          Text("New key term").foregroundStyle(palette.keyText.opacity(0.4))
        }
        Caret()
        Spacer(minLength: 0)
      }
      .font(.system(size: 17))
      .lineLimit(1)
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity)
      .frame(height: 36)
      .background(Capsule().fill(palette.keyDark))
      .overlay(Capsule().strokeBorder(BlurtBrand.greenOnDark.opacity(0.6), lineWidth: 1))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Key term: \(model.termDraft ?? "")")
      round("checkmark", tint: BlurtBrand.greenOnDark) { model.saveTerm() }
        .accessibilityLabel("Save the key term")
        .disabled(model.termDraft?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }
    .padding(.horizontal, 2)
  }

  private func round(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 32, height: 32)
        .background(Circle().fill(palette.keyDark))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
    .buttonStyle(KeyPressStyle())
  }
}

/// A blinking caret, as a text field's.
private struct Caret: View {
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
      let on = Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
      RoundedRectangle(cornerRadius: 1)
        .fill(BlurtBrand.greenOnDark)
        .frame(width: 2, height: 20)
        .opacity(on ? 1 : 0)
        .padding(.leading, 1)
    }
    .accessibilityHidden(true)
  }
}

/// The Mac pill's live meter: a row of bars that fills the width it is given
/// and tracks the current level, with the engine's envelope and idle wave
/// (`MeterBarGeometry`, unit-tested there). The keyboard hears the level from
/// the app at ~12 Hz; the wave keeps the row alive between ticks.
struct WaveformMeter: View {
  let level: Float
  let animated: Bool
  let color: Color

  var body: some View {
    GeometryReader { geo in
      let layout = MeterBarRow(availableSize: geo.size)
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
  }

  private func bars(layout: MeterBarRow, time: TimeInterval) -> some View {
    HStack(spacing: MeterBarGeometry.barSpacing) {
      ForEach(0..<layout.count, id: \.self) { index in
        Capsule()
          .fill(color)
          .frame(
            width: MeterBarGeometry.barWidth,
            height: layout.height(at: index, level: level, time: time, animated: animated))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
