import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// Where the element sits, for the sizes that differ.
nonisolated enum VoiceSlot: String, CaseIterable, Sendable {
  case bar
  case panel
  case home

  /// The box the element is given (`voice/*` tokens).
  var box: CGSize {
    let metrics = DesignTokens.Metrics.self
    return switch self {
    case .bar: CGSize(width: metrics.voiceBarWidth, height: metrics.voiceBarHeight)
    case .panel: CGSize(width: metrics.voicePanelWidth, height: metrics.voicePanelHeight)
    case .home: CGSize(width: metrics.voiceHomeWidth, height: metrics.voiceHomeHeight)
    }
  }
}

extension VoiceElementKind {
  /// How wide the element shows in a slot — what the + sits beside and the
  /// pair is centred on. The slot's box is the most it takes (the ribs awake,
  /// the streak); at rest the grille and the ribs are narrower, and a pair
  /// centred on the box would put the + off at the edge.
  func visibleWidth(slot: VoiceSlot, recording: Bool) -> CGFloat {
    switch self {
    case .grille: VoiceGrille.box(slot).width
    case .ribs: recording ? slot.box.width : DesignTokens.Metrics.ribsRestWidth
    case .streak: slot.box.width
    }
  }
}

/// Every candidate draws with a synchronous `Canvas`: one that renders
/// asynchronously never presents inside a keyboard extension, and the
/// keyboard is where these live.
///
/// Everything a candidate draws from — nothing else reaches it: the state,
/// the level inside it, the moment the words landed, whether motion is
/// allowed, the face's colours, and where it sits.
struct VoiceElementInputs {
  let state: VoiceState
  let landedAt: Date?
  let animated: Bool
  let palette: KeyboardPalette
  let slot: VoiceSlot
}

/// The seam: draws whichever kind the environment names.
struct VoiceElementView: View {
  let inputs: VoiceElementInputs
  @Environment(\.voiceElementKind) private var kind

  var body: some View {
    switch kind {
    case .grille: VoiceGrille(inputs: inputs)
    case .ribs: VoiceRibs(inputs: inputs)
    case .streak: VoiceStreak(inputs: inputs)
    }
  }
}

private struct VoiceElementKindKey: EnvironmentKey {
  static let defaultValue = VoiceElementKind.shipped
}

extension EnvironmentValues {
  var voiceElementKind: VoiceElementKind {
    get { self[VoiceElementKindKey.self] }
    set { self[VoiceElementKindKey.self] = newValue }
  }
}

/// The clocks the candidates share, so their motion cannot drift apart.
nonisolated enum VoiceClock {
  /// The landing glint's progress, 0 → 1 over `motion.landing` after the
  /// words landed; nil before and after.
  static func landing(landedAt: Date?, now: Date) -> Double? {
    guard let landedAt else { return nil }
    let elapsed = now.timeIntervalSince(landedAt)
    guard elapsed >= 0, elapsed < DesignTokens.Motion.landing else { return nil }
    return elapsed / DesignTokens.Motion.landing
  }

  /// Where the sheen's band is, 0 → 1 across the element and back to 0, on
  /// the rest period or the working one.
  static func sheen(time: TimeInterval, working: Bool) -> Double {
    let period = working ? DesignTokens.Motion.sheenWorking : DesignTokens.Motion.sheen
    return (time.truncatingRemainder(dividingBy: period)) / period
  }

  /// A small deterministic number in 0…1 for a facet and a moment — the
  /// glints are random to the eye and the same in every capture.
  static func hash(_ index: Int, _ tick: Int) -> Double {
    var state = UInt64(
      truncatingIfNeeded: index &* 6_364_136_223_846_793_005 &+ tick &* 1_442_695_040_888_963_407 &+ 17)
    state ^= state >> 29
    state = state &* 0x9E37_79B9_7F4A_7C15
    state ^= state >> 32
    return Double(state >> 40) / Double(1 << 24)
  }
}
