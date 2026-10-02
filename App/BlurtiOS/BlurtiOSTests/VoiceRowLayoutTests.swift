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
    let geometry = KeyGeometry(rowWidth: row)
    let letters = 7 * geometry.letterWidth + 6 * geometry.gap
    let punctuation = 5 * geometry.punctuationWidth + 4 * geometry.gap
    #expect(abs(letters - punctuation) < 0.001)
    #expect(geometry.punctuationWidth > geometry.letterWidth)
  }
}
