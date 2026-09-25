import BlurtEngine
import SwiftUI

/// The Mac's overlay pill, on the keyboard: an ink capsule with the orb fixed
/// at its left and, beside it, whatever the moment calls for — the live meter
/// while recording, a status word while waiting, the word alone for a notice.
/// One body for every state, the error included: the alarm is the orange
/// word, never a red capsule. Same inset (12), gap (8), rim and shadow as
/// `App/Blurt/Blurt/Overlay/OverlayView.swift`, at 36 pt instead of 28.
///
/// Unlike the Mac's, this pill is on screen at rest, so it also has things to
/// say before a dictation: that Full Access is missing, that the app isn't
/// listening, and how to start.
struct StatusPill: View {
  var model: KeyboardModel
  /// Shorter resting words, for the slim bar's narrow pill.
  var compact = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let height: CGFloat = 36
  /// The Mac's disc-to-pill ratio (24 in 40).
  static let orbDiameter: CGFloat = height * 0.6
  private static let inset: CGFloat = 12
  private static let spacing: CGFloat = 8

  var body: some View {
    content
      .frame(maxWidth: .infinity)
      .frame(height: Self.height)
      .background(Capsule().fill(BlurtBrand.ink))
      // The rim is what draws the capsule's edge on a dark surface like the
      // keyboard's own; the shadow carries it over light content.
      .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
      .compositingGroup()
      .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.snapshot.state)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
  }

  @ViewBuilder private var content: some View {
    if !model.hasFullAccess {
      word("Allow Full Access", color: BlurtBrand.errorOrange)
    } else if !model.isListening {
      orbLine(compact ? "Tap to start" : "Tap the mic to start", working: false)
    } else {
      switch model.snapshot.state {
      case .idle: orbLine(compact ? "Tap or hold" : "Tap or hold to talk", working: false)
      case .connecting: orbLine("Connecting", working: true)
      case .recording:
        HStack(spacing: Self.spacing) {
          BrandOrb(diameter: Self.orbDiameter, animated: !reduceMotion)
          WaveformMeter(level: Float(model.snapshot.level), animated: !reduceMotion, color: BlurtBrand.greenOnDark)
        }
        .padding(.horizontal, Self.inset)
        .transition(.opacity)
      case .processing: orbLine("Transcribing", working: true)
      case .pasted: word("Pasted")
      case .copied: word("Copied")
      case .error: word("Error", color: BlurtBrand.errorOrange)
      }
    }
  }

  /// The shape both waits share, and the resting line: orb, then the word.
  private func orbLine(_ text: String, working: Bool) -> some View {
    HStack(spacing: Self.spacing) {
      BrandOrb(diameter: Self.orbDiameter, animated: working && !reduceMotion)
      StatusLineText(text)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Self.inset)
    .transition(.opacity)
  }

  /// A notice: the word alone, centred.
  private func word(_ text: String, color: Color = BlurtBrand.greenOnDark) -> some View {
    StatusLineText(text, color: color)
      .padding(.horizontal, Self.inset)
      .transition(.opacity)
  }

  private var accessibilityLabel: String {
    guard model.hasFullAccess else { return "Blurt needs Full Access. Allow it in Settings, Keyboards." }
    guard model.isListening else { return "Blurt isn't listening. Tap the mic to open Blurt." }
    switch model.snapshot.state {
    case .idle: return "Tap the mic to talk, or hold it."
    case .connecting: return "Connecting to the microphone."
    case .recording: return "Recording."
    case .processing: return "Transcribing."
    case .pasted: return "Your dictation was inserted."
    case .copied: return "Your dictation was copied to the clipboard."
    case .error: return model.snapshot.message ?? "Dictation failed."
    }
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
