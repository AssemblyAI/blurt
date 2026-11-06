import BlurtDesign
import CoreFoundation
import Testing

@testable import BlurtiOS

/// The voice row's placement rules (`VoiceRowLayout`), at the iPhone 18 Pro's
/// row of 389 pt unless a case needs another: the mic dead centre or at an
/// edge, the + hanging off it, the chip growing away from it, the pair
/// centring when a chip has no room, and nothing ever negative.
@Suite("Voice row layout")
struct VoiceRowLayoutTests {
  private let row: CGFloat = 389
  private let mic: CGFloat = 64
  private let key: CGFloat = 43.333
  private let hit = DesignTokens.Metrics.glyphHit
  private let clearance = DesignTokens.Metrics.voicebarAddtermClearance

  private func layout(_ side: VoiceRowLayout.Side, row: CGFloat? = nil) -> VoiceRowLayout {
    VoiceRowLayout(rowWidth: row ?? self.row, side: side)
  }

  @Test("centred: the mic's centre is the row's; the + hangs a clearance off its trailing edge, the × mirrors it")
  func centred() {
    let placed = layout(.center).place(micWidth: mic, minMicWidth: key, chip: false)
    #expect(!placed.paired)
    #expect(placed.micWidth == mic)
    #expect(abs(placed.micX + mic / 2 - row / 2) < 0.001)
    #expect(placed.addX == placed.micX + mic + clearance)
    #expect(placed.addWidth == hit)
    #expect(placed.addGrowsTrailing)
    #expect(placed.cancelX == placed.micX - clearance - hit)
    // The + and the × sit the same distance from the mic on either side.
    let plusGap = placed.addX - (placed.micX + mic)
    let cancelGap = placed.micX - ((placed.cancelX ?? 0) + hit)
    #expect(abs(plusGap - cancelGap) < 0.001)
  }

  @Test("centred with a chip: the chip takes everything from the mic to the row's edge, the mic stays put")
  func centredChip() {
    let plain = layout(.center).place(micWidth: mic, minMicWidth: key, chip: false)
    let chip = layout(.center).place(micWidth: mic, minMicWidth: key, chip: true)
    #expect(!chip.paired)
    #expect(chip.micX == plain.micX)
    #expect(chip.addX == plain.addX)
    #expect(abs(chip.addX + chip.addWidth - row) < 0.001)
    #expect(chip.addWidth >= DesignTokens.Metrics.addtermChipMinWidth)
  }

  @Test("the panel's 160 pt grille still leaves a chip its minimum on the iPhone 18 Pro")
  func panelChip() {
    let placed = layout(.center).place(micWidth: 160, minMicWidth: key, chip: true)
    #expect(!placed.paired)
    #expect(placed.addWidth >= DesignTokens.Metrics.addtermChipMinWidth)
  }

  @Test(
    "the slim bar's row cannot hold a chip beside a centred mic: the pair centres, the chip takes what the mic leaves")
  func slimBarPairs() {
    // The row between the globe, delete and return at the full keyboard's
    // widths (191.67), and without the globe (247.5).
    for width in [191.667, 247.5] as [CGFloat] {
      let placed = layout(.center, row: width).place(micWidth: mic, minMicWidth: key, chip: true)
      #expect(placed.paired, "\(width)")
      #expect(placed.micWidth == mic)
      #expect(abs(placed.addWidth - (width - mic - clearance)) < 0.001)
      #expect(placed.addWidth > 0)
    }
    // The + alone always fits beside the centred mic there.
    let plus = layout(.center, row: 191.667).place(micWidth: mic, minMicWidth: key, chip: false)
    #expect(!plus.paired)
    #expect(plus.addX + plus.addWidth <= 191.667)
  }

  @Test("the mic key is never narrower than a key nor wider than the row, and the + never leaves the row")
  func clamps() {
    let narrow = layout(.center).place(micWidth: 10, minMicWidth: key, chip: false)
    #expect(narrow.micWidth == key)
    let wide = layout(.center).place(micWidth: 1000, minMicWidth: key, chip: false)
    #expect(wide.micWidth == row)
    #expect(wide.micX == 0)
    #expect(wide.addX + wide.addWidth <= row)
    #expect(wide.cancelX == 0)
    // A tiny row with a chip: still nothing negative.
    let tiny = layout(.center, row: 60).place(micWidth: mic, minMicWidth: key, chip: true)
    #expect(tiny.micWidth == 60)
    #expect(tiny.addWidth == 0)
    #expect(tiny.paired)
  }

  @Test("at the leading edge the mic is at the edge and the + on its inner side; a chip grows to the far edge")
  func leading() {
    let plus = layout(.leading).place(micWidth: mic, minMicWidth: key, chip: false)
    #expect(plus.micX == 0)
    #expect(plus.addX == mic + clearance)
    #expect(plus.addWidth == hit)
    #expect(plus.addGrowsTrailing)
    #expect(plus.cancelX == nil)
    let chip = layout(.leading).place(micWidth: mic, minMicWidth: key, chip: true)
    #expect(abs(chip.addX + chip.addWidth - row) < 0.001)
  }

  @Test("at the trailing edge the mic is at the edge and the + on its inner side, growing towards the leading edge")
  func trailing() {
    let plus = layout(.trailing).place(micWidth: mic, minMicWidth: key, chip: false)
    #expect(abs(plus.micX + mic - row) < 0.001)
    #expect(plus.addWidth == hit)
    #expect(abs(plus.addX + hit + clearance - plus.micX) < 0.001)
    #expect(!plus.addGrowsTrailing)
    #expect(plus.cancelX == nil)
    let chip = layout(.trailing).place(micWidth: mic, minMicWidth: key, chip: true)
    #expect(chip.addX == 0)
    #expect(abs(chip.addWidth + clearance - chip.micX) < 0.001)
  }

  @Test("the row's side follows the alignment Settings chose, flipped for a right-to-left language")
  func sides() {
    #expect(VoiceRow.side(.center, in: .leftToRight) == .center)
    #expect(VoiceRow.side(.left, in: .leftToRight) == .leading)
    #expect(VoiceRow.side(.right, in: .leftToRight) == .trailing)
    #expect(VoiceRow.side(.left, in: .rightToLeft) == .trailing)
    #expect(VoiceRow.side(.right, in: .rightToLeft) == .leading)
  }

  @Test("the full keyboard's symbol pages: five punctuation keys fill what seven letters do")
  func punctuation() {
    for generation in [KeyboardProfile.Generation.classic, .glass] {
      let profile = KeyboardProfile(generation: generation, width: 402, hasGlobe: false)
      let geometry = KeyGeometry(rowWidth: row, profile: profile)
      let letters = 7 * geometry.letterWidth + 6 * geometry.gap
      let punctuation = 5 * geometry.punctuationWidth + 4 * geometry.gap
      #expect(abs(letters - punctuation) < 0.001, "\(generation)")
      #expect(geometry.punctuationWidth > geometry.letterWidth, "\(generation)")
    }
  }

  @Test(
    "the panel's grille at every phone's row: the + and the × beside it, never over it, inside the row",
    arguments: [362, 377, 389, 417] as [CGFloat])
  func panelRows(row: CGFloat) {
    // The rows inside the classic margins at 375 and 390 (3 pt), the glass
    // ones at 402 and 430 (6.5 pt); the grille shows 160 wide in the panel.
    let grille = DesignTokens.Metrics.grillePanelWidth
    let cap = PanelView.micCap(rowWidth: row)
    let placed = layout(.center, row: row).place(micWidth: min(grille, cap), minMicWidth: key, chip: false)
    #expect(!placed.paired)
    #expect(abs(placed.micX + placed.micWidth / 2 - row / 2) < 0.001, "the mic's centre is the row's")
    #expect(placed.addX >= placed.micX + placed.micWidth + clearance - 0.001, "the + clear of the mic")
    #expect(placed.addX + placed.addWidth <= row + 0.001, "the + inside the row")
    let cancelX = placed.cancelX ?? -1
    #expect(cancelX >= 0 && cancelX + hit <= placed.micX - clearance + 0.001, "the × clear of the mic, inside the row")
    // A chip has its minimum beside the grille, or — on the narrowest row,
    // where it has not — the pair centres as designed, the mic moving over.
    let chip = layout(.center, row: row).place(micWidth: min(grille, cap), minMicWidth: key, chip: true)
    #expect(chip.paired || chip.addWidth >= DesignTokens.Metrics.addtermChipMinWidth, "\(row)")
    #expect(chip.addWidth > 0 && chip.micWidth == placed.micWidth, "\(row)")
  }

  @Test("a capped add box never grows past its cap and never moves the mic")
  func addCap() {
    let capped = layout(.center).place(micWidth: mic, minMicWidth: key, chip: true, addCap: 60)
    let plain = layout(.center).place(micWidth: mic, minMicWidth: key, chip: false)
    #expect(!capped.paired)
    #expect(capped.micX == plain.micX && capped.addX == plain.addX)
    #expect(capped.addWidth == 60)
    // Below the chip's minimum the pair would centre; with a cap the mic stays put.
    let narrow = layout(.center, row: 191.667).place(micWidth: mic, minMicWidth: key, chip: true, addCap: 50)
    #expect(!narrow.paired && narrow.addWidth == 50)
    let trailing = layout(.trailing).place(micWidth: mic, minMicWidth: key, chip: true, addCap: 60)
    #expect(trailing.addWidth == 60 && abs(trailing.addX + 60 + clearance - trailing.micX) < 0.001)
    let leading = layout(.leading).place(micWidth: mic, minMicWidth: key, chip: true, addCap: 60)
    #expect(leading.addWidth == 60 && leading.addX == mic + clearance)
  }
}

/// The slim bar's keys around the mic `VoiceRowLayout` places
/// (`SlimBarLayout`): the mic at the keyboard's centre or its edge, the +
/// beside it, delete and return hanging after them and the globe at an
/// edge — at the classic 390's row (384) and the glass 402's (389).
@Suite("Slim bar layout")
struct SlimBarLayoutTests {
  private let mic: CGFloat = 64
  private let hit = DesignTokens.Metrics.glyphHit
  private let clearance = DesignTokens.Metrics.voicebarAddtermClearance

  private static let rows: [(KeyboardProfile.Generation, CGFloat)] = [(.classic, 390), (.glass, 402)]

  private func bar(_ generation: KeyboardProfile.Generation, width: CGFloat, side: VoiceRowLayout.Side, globe: Bool)
    -> (SlimBarLayout, KeyGeometry)
  {
    let profile = KeyboardProfile(generation: generation, width: width, hasGlobe: globe)
    let geometry = KeyGeometry(width: width, profile: profile)
    let layout = SlimBarLayout(
      rowWidth: geometry.rowWidth, side: side, globe: globe, abcWidth: geometry.abcWidth,
      returnWidth: geometry.returnWidth, gap: geometry.gap)
    return (layout, geometry)
  }

  @Test("centred: the mic's centre is the keyboard's, delete and return hang after the +, return runs to the edge")
  func centred() {
    for (generation, width) in Self.rows {
      for globe in [false, true] {
        let (layout, geometry) = bar(generation, width: width, side: .center, globe: globe)
        let row = geometry.rowWidth
        let placed = VoiceRowLayout(rowWidth: row, side: .center)
          .place(micWidth: mic, minMicWidth: geometry.abcWidth, chip: false, addCap: layout.addCap(micWidth: mic))
        let keys = layout.keys(micWidth: mic, chip: false)
        #expect(abs(placed.micX + mic / 2 - row / 2) < 0.001, "\(generation) \(width): the mic on the centre line")
        #expect(keys.globeX == (globe ? 0 : nil))
        #expect(abs(keys.deleteX - (placed.addX + hit + geometry.gap)) < 0.001, "delete after the +")
        #expect(abs(keys.returnX - (keys.deleteX + geometry.abcWidth + geometry.gap)) < 0.001)
        #expect(abs(keys.returnX + keys.returnWidth - row) < 0.001, "return to the edge")
        #expect(keys.returnWidth >= geometry.abcWidth, "return at least a 123 key wide")
        // The + alone never needs the cap.
        #expect(placed.addWidth == hit)
        // The note without Full Access takes the room between the globe and delete.
        #expect(abs(keys.noteX - (globe ? geometry.abcWidth + geometry.gap : 0)) < 0.001)
        #expect(abs(keys.noteX + keys.noteWidth + geometry.gap - keys.deleteX) < 0.001)
      }
    }
  }

  @Test("centred with a chip: the chip grows only as far as leaves delete and a 123-wide return, which slide over")
  func centredChip() {
    for (generation, width) in Self.rows {
      let (layout, geometry) = bar(generation, width: width, side: .center, globe: false)
      let row = geometry.rowWidth
      let cap = layout.addCap(micWidth: mic)
      let placed = VoiceRowLayout(rowWidth: row, side: .center)
        .place(micWidth: mic, minMicWidth: geometry.abcWidth, chip: true, addCap: cap)
      let keys = layout.keys(micWidth: mic, chip: true)
      #expect(!placed.paired, "the mic stays put")
      #expect(placed.addWidth == cap && cap >= hit)
      #expect(abs(keys.deleteX - (placed.addX + cap + geometry.gap)) < 0.001)
      #expect(abs(keys.returnWidth - geometry.abcWidth) < 0.001, "\(generation) \(width): return at its least")
      #expect(abs(keys.returnX + keys.returnWidth - row) < 0.001)
    }
  }

  @Test("at the leading edge: the mic at the edge, the + inboard, then delete and return, the globe at the far edge")
  func leading() {
    for (generation, width) in Self.rows {
      let (layout, geometry) = bar(generation, width: width, side: .leading, globe: true)
      let row = geometry.rowWidth
      let keys = layout.keys(micWidth: mic, chip: false)
      #expect(abs(keys.deleteX - (mic + clearance + hit + geometry.gap)) < 0.001, "\(generation) \(width)")
      #expect(abs(keys.returnX - (keys.deleteX + geometry.abcWidth + geometry.gap)) < 0.001)
      #expect(keys.returnWidth == geometry.returnWidth)
      #expect(keys.globeX == row - geometry.abcWidth)
      #expect(keys.returnX + keys.returnWidth + geometry.gap <= (keys.globeX ?? row) + 0.001, "nothing overlaps")
      #expect(keys.noteX == 0 && abs(keys.noteX + keys.noteWidth + geometry.gap - keys.deleteX) < 0.001)
      // A chip stops short of the keys.
      let chip = layout.keys(micWidth: mic, chip: true)
      #expect(chip.returnX + chip.returnWidth + geometry.gap <= (chip.globeX ?? row) + 0.001)
    }
  }

  @Test("at the trailing edge: the mic at the edge, the + inboard, delete and return before it, the globe leading")
  func trailing() {
    for (generation, width) in Self.rows {
      let (layout, geometry) = bar(generation, width: width, side: .trailing, globe: true)
      let row = geometry.rowWidth
      let placed = VoiceRowLayout(rowWidth: row, side: .trailing)
        .place(micWidth: mic, minMicWidth: geometry.abcWidth, chip: false, addCap: layout.addCap(micWidth: mic))
      let keys = layout.keys(micWidth: mic, chip: false)
      #expect(abs(placed.micX + mic - row) < 0.001, "\(generation) \(width): the mic at the edge")
      #expect(abs(keys.returnX + keys.returnWidth + geometry.gap - placed.addX) < 0.001, "return before the +")
      #expect(abs(keys.deleteX + geometry.abcWidth + geometry.gap - keys.returnX) < 0.001)
      #expect(keys.globeX == 0)
      #expect(keys.deleteX >= geometry.abcWidth + geometry.gap - 0.001, "delete clear of the globe")
      #expect(abs(keys.noteX - (keys.returnX + keys.returnWidth + geometry.gap)) < 0.001)
      #expect(abs(keys.noteX + keys.noteWidth - row) < 0.001)
      let chip = layout.keys(micWidth: mic, chip: true)
      #expect(chip.deleteX >= geometry.abcWidth + geometry.gap - 0.001, "a chip never pushes delete into the globe")
    }
  }
}
