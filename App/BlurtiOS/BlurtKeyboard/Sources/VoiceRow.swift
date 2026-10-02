import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// The voice row's arithmetic, out of the views, so the bar, the panel and
/// the slim bar place the mic key and the add key one way and the numbers
/// can be tested (DESIGN.md › Layouts).
///
/// The mic key is what is placed: dead centre of the row, or at the edge
/// Settings chose (`MicAlignment`). The add key — the +, or the chip for a
/// highlighted word — hangs off the mic a clearance away, at the mic's own
/// vertical centre: on its trailing side in the middle, on its inner side at
/// an edge, so the mic is always the thing at the edge. A chip grows away
/// from the mic as far as the row allows. When a chip has less than its
/// minimum beside a centred mic (the slim bar), the mic and the chip centre
/// as a pair instead: the mic moves over rather than the chip collapsing
/// onto it. In the panel the cancel × mirrors the add key on the mic's other
/// side, so the row reads × · mic · + while something is in flight.
nonisolated struct VoiceRowLayout: Equatable {
  enum Side: Equatable {
    case center
    case leading
    case trailing
  }

  /// Where things go, in points from the row's leading edge.
  struct Placement: Equatable {
    /// The mic key's leading edge and width.
    let micX: CGFloat
    let micWidth: CGFloat
    /// The add key's box: the + sits at the box's mic-side edge; a chip hugs
    /// that edge and may grow to the box's far one.
    let addX: CGFloat
    let addWidth: CGFloat
    /// Whether the box's mic-side edge is its leading one — the box grows
    /// towards the trailing edge.
    let addGrowsTrailing: Bool
    /// The cancel key's leading edge, mirroring the + on the mic's other
    /// side; nil at an edge, where cancel goes to the far corner instead.
    let cancelX: CGFloat?
    /// The mic and the chip centred together as a pair, the mic moved over:
    /// `micX` and `addX` are then unused and `addWidth` is the chip's most.
    let paired: Bool
  }

  let rowWidth: CGFloat
  let side: Side
  /// Between the mic key's edge and the add key's box.
  let clearance: CGFloat
  /// The +'s box, a square.
  let glyphHit: CGFloat
  /// The least a chip needs beside a centred mic before the pair centres instead.
  let chipMinWidth: CGFloat

  init(
    rowWidth: CGFloat, side: Side, clearance: CGFloat = DesignTokens.Metrics.voicebarAddtermClearance,
    glyphHit: CGFloat = DesignTokens.Metrics.glyphHit, chipMinWidth: CGFloat = DesignTokens.Metrics.addtermChipMinWidth
  ) {
    self.rowWidth = rowWidth
    self.side = side
    self.clearance = clearance
    self.glyphHit = glyphHit
    self.chipMinWidth = chipMinWidth
  }

  /// Places a mic key that shows `shown` wide — never narrower than
  /// `minMicWidth` (a key), never wider than the row — with the + beside it,
  /// or a chip when `chip`.
  func place(micWidth shown: CGFloat, minMicWidth: CGFloat, chip: Bool) -> Placement {
    let mic = min(rowWidth, max(minMicWidth, shown))
    switch side {
    case .leading:
      let addX = mic + clearance
      let room = max(0, rowWidth - addX)
      return Placement(
        micX: 0, micWidth: mic, addX: addX, addWidth: chip ? room : min(glyphHit, room), addGrowsTrailing: true,
        cancelX: nil, paired: false)
    case .trailing:
      let micX = rowWidth - mic
      let room = max(0, micX - clearance)
      let width = chip ? room : min(glyphHit, room)
      return Placement(
        micX: micX, micWidth: mic, addX: room - width, addWidth: width, addGrowsTrailing: false, cancelX: nil,
        paired: false)
    case .center:
      let micX = (rowWidth - mic) / 2  // literal-ok: centred
      let addX = micX + mic + clearance
      let room = max(0, rowWidth - addX)
      if chip, room < chipMinWidth {
        // Not enough beside a centred mic: the pair centres, the chip taking
        // what the mic leaves.
        return Placement(
          micX: 0, micWidth: mic, addX: 0, addWidth: max(0, rowWidth - mic - clearance), addGrowsTrailing: true,
          cancelX: nil, paired: true)
      }
      // The + never leaves the row: beside a mic wider than the row allows
      // it moves in over the mic's edge, and so does its mirror.
      let plusX = max(0, min(addX, rowWidth - glyphHit))
      let cancelX = max(0, min(micX - clearance - glyphHit, rowWidth - glyphHit))
      return Placement(
        micX: micX, micWidth: mic, addX: chip ? addX : plusX, addWidth: chip ? room : glyphHit, addGrowsTrailing: true,
        cancelX: cancelX, paired: false)
    }
  }
}

/// The row itself: the mic key where `VoiceRowLayout` puts it, the add key
/// hanging off it and — where `cancels` — the cancel × mirroring the add key
/// while a dictation is in flight. Fills the width it is given; `height` is
/// the row's, and the mic key's touch target is that tall.
struct VoiceRow: View {
  var model: KeyboardModel
  let slot: VoiceSlot
  let height: CGFloat
  var cancels = false
  @Environment(\.keyboardPalette) private var palette
  @Environment(\.voiceElementKind) private var kind
  @Environment(\.layoutDirection) private var direction

  var body: some View {
    GeometryReader { geo in
      let recording = model.voiceState.isRecording
      let chip = model.selectedTerm != nil
      let layout = VoiceRowLayout(rowWidth: geo.size.width, side: Self.side(model.micAlignment, in: direction))
      let placed = layout.place(
        micWidth: kind.visibleWidth(slot: slot, recording: recording), minMicWidth: DesignTokens.Metrics.keyMinWidth,
        chip: chip)
      let cancel = cancels && model.voiceState.canCancel
      ZStack(alignment: .leading) {
        if placed.paired {
          // The chip at its own width, capped — a frame would stretch to the
          // cap and the pair would sit off centre.
          HStack(spacing: layout.clearance) {
            if cancel { cancelKey.transition(.opacity) }
            MicControl(model: model, slot: slot, width: placed.micWidth, hitHeight: height)
            CappedWidth(cap: placed.addWidth) { AddTermKey(model: model) }
          }
          .frame(maxWidth: .infinity)
        } else {
          MicControl(model: model, slot: slot, width: placed.micWidth, hitHeight: height)
            .padding(.leading, placed.micX)
          AddTermKey(model: model)
            .frame(width: placed.addWidth, alignment: placed.addGrowsTrailing ? .leading : .trailing)
            .padding(.leading, placed.addX)
          if cancel, let cancelX = placed.cancelX {
            cancelKey.padding(.leading, cancelX).transition(.opacity)
          }
        }
      }
      .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
      .animation(.easeInOut(duration: DesignTokens.Motion.waveFade), value: recording)
      .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: chip)
      .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: cancel)
    }
    .frame(height: height)
  }

  private var cancelKey: some View {
    GlyphKey(symbol: "xmark", tint: palette.notice, label: "Cancel dictation") { model.cancel() }
  }

  /// The row's side for the alignment Settings chose, as SwiftUI counts sides.
  static func side(_ alignment: MicAlignment, in direction: LayoutDirection) -> VoiceRowLayout.Side {
    switch alignment.alignment(in: direction) {
    case .leading: .leading
    case .trailing: .trailing
    default: .center
    }
  }
}

/// A bare glyph as a key — the +, × and ✓: an SF Symbol at `size/glyph` in a
/// `glyph/hit` square (the HIG's 44 pt), no cap, lighting while pressed. One
/// shape wherever a glyph is a key, so the row's furniture matches.
struct GlyphKey: View {
  let symbol: String
  let tint: Color
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
        .foregroundStyle(tint)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: DesignTokens.Metrics.glyphHit, height: DesignTokens.Metrics.glyphHit)
        .contentShape(Rectangle())
    }
    .buttonStyle(KeyPressStyle())
    .accessibilityLabel(label)
  }
}

/// One view at its own width, but never wider than `cap`: what a chip needs
/// when it is centred with the mic as a pair. (`frame(maxWidth:)` is greedy —
/// it takes the cap whatever the content wants.)
struct CappedWidth: Layout {
  let cap: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    let ideal = subview.sizeThatFits(.unspecified)
    let width = min(ideal.width, cap, proposal.width ?? .infinity)
    return subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
  }
}
