import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// One row, placed in the keyboard's own coordinates: the mic key dead
/// centre of the keyboard (centre = W/2, as the Settings copy says) with
/// the + hanging off its trailing side and delete and return hanging after
/// that, return running to the edge; the globe (when the phone doesn't draw
/// its own) at the leading edge. At an edge the mic is the thing at the
/// edge, the + on its inner side, delete and return inboard of them at the
/// full keyboard's widths, and the globe at the far edge. The keys are as
/// tall as the row, so nothing sits half a point off. `SlimBarLayout` is the
/// arithmetic (tested); the row itself is `VoiceBar` over the whole width —
/// or, without Full Access, its note where the mic would be.
struct SlimBarView: View {
  var model: KeyboardModel
  @Environment(\.keyboardProfile) private var profile
  @Environment(\.voiceElementKind) private var kind
  @Environment(\.layoutDirection) private var direction

  var body: some View {
    GeometryReader { geo in
      let geometry = KeyGeometry(rowWidth: geo.size.width, profile: profile)
      let height = VoiceBar.height
      let layout = SlimBarLayout(
        rowWidth: geo.size.width, side: VoiceRow.side(model.micAlignment, in: direction), globe: model.needsGlobe,
        abcWidth: geometry.abcWidth, returnWidth: geometry.returnWidth, gap: geometry.gap)
      let mic = kind.visibleWidth(slot: .bar, recording: model.voiceState.isRecording)
      let keys = layout.keys(micWidth: mic, chip: model.selectedTerm != nil)
      ZStack(alignment: .leading) {
        if model.hasFullAccess {
          // The mic and the + placed by `VoiceRowLayout` over the whole row,
          // the chip capped so the keys keep their room.
          VoiceBar(model: model, addCap: layout.addCap(micWidth: mic))
        } else {
          // The note, between the globe and the keys.
          VoiceBar(model: model)
            .frame(width: keys.noteWidth)
            .padding(.leading, keys.noteX)
        }
        if let globeX = keys.globeX {
          KeyCap(systemImage: "globe", dark: true, width: geometry.abcWidth, height: height) { model.globe() }
            .padding(.leading, globeX)
        }
        KeyCap(systemImage: "delete.left", dark: true, width: geometry.abcWidth, height: height) {
          model.deleteBackward()
        }
        .padding(.leading, keys.deleteX)
        KeyCap(title: model.returnLabel ?? "return", dark: true, width: keys.returnWidth, height: height) {
          model.newline()
        }
        .padding(.leading, keys.returnX)
      }
      .frame(width: geo.size.width, height: height, alignment: .leading)
      .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: model.selectedTerm == nil)
    }
    .frame(height: VoiceBar.height)
  }
}

/// Where the slim bar's keys go around the mic and the + that
/// `VoiceRowLayout` places, in points from the row's leading edge. Centred:
/// delete and return hang after the add key's box, return taking the rest of
/// the row, the globe at the leading edge. At the leading edge (the mic
/// there): delete and return inboard after the +, the globe at the trailing
/// edge. At the trailing edge: delete and return inboard before the +, the
/// globe at the leading edge. The chip never grows into the keys: `addCap`
/// is the most the add box may take and leave them their width — return at
/// least a 123 key wide when it runs to the edge.
nonisolated struct SlimBarLayout: Equatable {
  struct Keys: Equatable {
    let globeX: CGFloat?
    let deleteX: CGFloat
    let returnX: CGFloat
    let returnWidth: CGFloat
    /// The room between the globe and the keys, where the mic and the +
    /// go: what the Full Access note takes when there is no mic to show.
    let noteX: CGFloat
    let noteWidth: CGFloat
  }

  let rowWidth: CGFloat
  let side: VoiceRowLayout.Side
  let globe: Bool
  let abcWidth: CGFloat
  let returnWidth: CGFloat
  let gap: CGFloat
  let minMicWidth: CGFloat
  let clearance: CGFloat
  let glyphHit: CGFloat

  init(
    rowWidth: CGFloat, side: VoiceRowLayout.Side, globe: Bool, abcWidth: CGFloat, returnWidth: CGFloat, gap: CGFloat,
    minMicWidth: CGFloat = DesignTokens.Metrics.keyMinWidth,
    clearance: CGFloat = DesignTokens.Metrics.voicebarAddtermClearance,
    glyphHit: CGFloat = DesignTokens.Metrics.glyphHit
  ) {
    self.rowWidth = rowWidth
    self.side = side
    self.globe = globe
    self.abcWidth = abcWidth
    self.returnWidth = returnWidth
    self.gap = gap
    self.minMicWidth = minMicWidth
    self.clearance = clearance
    self.glyphHit = glyphHit
  }

  private var voice: VoiceRowLayout {
    VoiceRowLayout(rowWidth: rowWidth, side: side, clearance: clearance, glyphHit: glyphHit)
  }

  /// The width the keys need beside the add box, gaps included: delete, the
  /// return (its full width inboard, a 123 key's at least when it runs to
  /// the edge) and the globe when it sits inboard too.
  private var keysWidth: CGFloat {
    let returnMin = side == .center ? abcWidth : returnWidth
    let globeWidth = globe && side == .trailing ? abcWidth + gap : 0
    return gap + abcWidth + gap + returnMin + globeWidth
  }

  /// The most the add box (the + or the chip) may take beside a mic this
  /// wide, keeping the keys their room; never less than the +'s square.
  func addCap(micWidth: CGFloat) -> CGFloat {
    let mic = min(rowWidth, max(minMicWidth, micWidth))
    let room: CGFloat =
      switch side {
      case .center: rowWidth - ((rowWidth - mic) / 2 + mic + clearance)  // literal-ok: centred
      case .leading: rowWidth - (mic + clearance) - (globe ? abcWidth + gap : 0)
      case .trailing: rowWidth - mic - clearance
      }
    return max(glyphHit, room - keysWidth)
  }

  /// The keys' places for a mic this wide, with the + or a chip beside it.
  func keys(micWidth: CGFloat, chip: Bool) -> Keys {
    let placed = voice.place(
      micWidth: micWidth, minMicWidth: minMicWidth, chip: chip, addCap: addCap(micWidth: micWidth))
    let globeEnd = globe ? abcWidth + gap : 0
    switch side {
    case .center:
      let deleteX = placed.addX + placed.addWidth + gap
      let returnX = deleteX + abcWidth + gap
      return Keys(
        globeX: globe ? 0 : nil, deleteX: deleteX, returnX: returnX, returnWidth: rowWidth - returnX, noteX: globeEnd,
        noteWidth: max(0, deleteX - gap - globeEnd))
    case .leading:
      let deleteX = placed.addX + placed.addWidth + gap
      return Keys(
        globeX: globe ? rowWidth - abcWidth : nil, deleteX: deleteX, returnX: deleteX + abcWidth + gap,
        returnWidth: returnWidth, noteX: 0, noteWidth: max(0, deleteX - gap))
    case .trailing:
      let returnX = placed.addX - gap - returnWidth
      let noteX = returnX + returnWidth + gap
      return Keys(
        globeX: globe ? 0 : nil, deleteX: returnX - gap - abcWidth, returnX: returnX, returnWidth: returnWidth,
        noteX: noteX, noteWidth: max(0, rowWidth - noteX))
    }
  }
}
