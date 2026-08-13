import Foundation
import Testing

@testable import BlurtEngine

/// The account row's projection of the stored key. The masking rule is the point:
/// it lived in a SwiftUI view as a bare `"••••\(savedKey.suffix(4))"`, where a
/// key shorter than the revealed tail rendered the *whole* secret on screen and
/// nothing could catch it.
@Suite("APIKeyDisplay")
struct APIKeyDisplayTests {
  /// A realistically-shaped AssemblyAI key (32 hex characters).
  private let realKey = "0123456789abcdef0123456789abcdef"

  @Test("no key reads as not connected")
  func noKey() {
    #expect(APIKeyDisplay.resolve(key: nil) == .notConnected)
    #expect(APIKeyDisplay.resolve(key: "") == .notConnected)
  }

  @Test("a whitespace-only key is no key at all")
  func blankKey() {
    // Matches how `APIKeyGateway` treats it (a whitespace write is a delete), so
    // the row can't claim "Connected" over a key the store considers absent.
    #expect(APIKeyDisplay.resolve(key: "   \n\t ") == .notConnected)
  }

  @Test("a stored key shows only its last four characters")
  func maskedTail() {
    let display = APIKeyDisplay.resolve(key: realKey)
    #expect(display == .connected(maskedTail: "••••cdef"))
    #expect(display.statusText == "••••cdef")
    #expect(display.isConnected)
    // The four revealed characters read as an identifier, so the shell monospaces
    // them rather than setting them as prose.
    #expect(display.rendersIdentifier)
  }

  @Test("the mask never reveals more than the tail length")
  func maskRevealsOnlyTheTail() {
    let display = APIKeyDisplay.resolve(key: realKey)
    let text = display.statusText
    // Everything but the tail must be gone from the rendered string — not merely
    // shortened. This is the assertion the old view code would have failed.
    let hidden = String(realKey.dropLast(APIKeyDisplay.revealedTailLength))
    #expect(!text.contains(hidden))
    #expect(text.hasSuffix(String(realKey.suffix(APIKeyDisplay.revealedTailLength))))
  }

  @Test("a key too short to mask is never partially revealed")
  func shortKeyRevealsNothing() {
    // The regression this rule exists for: with a fixed `suffix(4)`, a 4- or
    // 3-character key put the entire secret on screen. Below the threshold the
    // row says "Connected" and shows none of it.
    for short in ["k", "ab", "sk-1", "sk-1234"] {
      let display = APIKeyDisplay.resolve(key: short)
      #expect(display == .connected(maskedTail: nil))
      #expect(display.statusText == "Connected")
      #expect(display.isConnected)
      // Prose, not an identifier — nothing to line up.
      #expect(!display.rendersIdentifier)
      #expect(!display.statusText.contains(short))
    }
  }

  @Test("the not-connected row reads as prose, not as an identifier")
  func notConnectedIsProse() {
    // Every other `!rendersIdentifier` assertion here is about `.connected(nil)` — a
    // short key that gets masked to bare "Connected" — so the `.notConnected` arm was
    // unpinned, and flipping it to `true` survived the whole suite
    // (`scripts/mutate.sh`). Monospacing "Not connected" would style a sentence as a
    // value.
    #expect(!APIKeyDisplay.notConnected.rendersIdentifier)
  }

  @Test("the threshold keeps at least half of any masked key hidden")
  func thresholdIsTwiceTheTail() {
    #expect(APIKeyDisplay.minimumLengthToMask == APIKeyDisplay.revealedTailLength * 2)
    // Exactly at the threshold: masked, and half the key is still hidden.
    let atThreshold = String(repeating: "x", count: APIKeyDisplay.minimumLengthToMask)
    #expect(APIKeyDisplay.resolve(key: atThreshold).rendersIdentifier)
    // One character below: not masked at all.
    #expect(!APIKeyDisplay.resolve(key: String(atThreshold.dropLast())).rendersIdentifier)
  }

  @Test("the key is trimmed before masking, so the tail is real characters")
  func trailingWhitespaceDoesNotBecomeTheTail() {
    // A pasted key with a trailing newline must not render "••••def\n" — the
    // store trims on write, so the display has to agree.
    let display = APIKeyDisplay.resolve(key: "  \(realKey)\n")
    #expect(display == .connected(maskedTail: "••••cdef"))
  }

  @Test("VoiceOver spells the state out instead of speaking the bullets")
  func accessibilityLabels() {
    #expect(APIKeyDisplay.resolve(key: nil).accessibilityLabel == "Not connected")
    #expect(
      APIKeyDisplay.resolve(key: realKey).accessibilityLabel == "Connected, key ending cdef")
    // No tail to name, so no misleading "key ending" clause.
    #expect(APIKeyDisplay.resolve(key: "sk-1").accessibilityLabel == "Connected")
  }

  @Test("the accessibility label never speaks the mask characters")
  func accessibilityLabelDropsTheMask() {
    #expect(!APIKeyDisplay.resolve(key: realKey).accessibilityLabel.contains("•"))
  }

  @Test("control titles switch between first-connect and rotate wording")
  func buttonTitles() {
    let empty = APIKeyDisplay.resolve(key: nil)
    let stored = APIKeyDisplay.resolve(key: realKey)
    // The row's button opens a sheet, so both titles keep the ellipsis.
    #expect(empty.editButtonTitle == "Connect…")
    #expect(stored.editButtonTitle == "Change…")
    // The sheet's default action commits, so neither does.
    #expect(empty.commitButtonTitle == "Connect")
    #expect(stored.commitButtonTitle == "Update")
    #expect(!empty.commitButtonTitle.hasSuffix("…"))
    #expect(!stored.commitButtonTitle.hasSuffix("…"))
  }

  @Test("the sheet's rationale explains the first connect, then the rotation")
  func rationale() {
    #expect(APIKeyDisplay.resolve(key: nil).rationale.contains("needs an AssemblyAI API key"))
    #expect(APIKeyDisplay.resolve(key: realKey).rationale.contains("replace"))
  }
}
