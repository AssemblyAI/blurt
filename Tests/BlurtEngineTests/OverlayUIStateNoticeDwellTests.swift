import Foundation
import Testing

@testable import BlurtEngine

/// `noticeDwellSeconds` decides whether the shell holds a state or flashes it
/// and reverts to `.idle` (nil = held), and for how long. Getting this wrong
/// would either pin a "copied" notice on the pill forever or drop the recording
/// indicator, so pin every case. The policy lives on the state (not in the
/// AppKit controller) so a new notice can't ship without a dwell, and the
/// asymmetry — errors linger to be read, a successful "Pasted" clears fast —
/// is pinned here.
@Suite("OverlayUIState.noticeDwellSeconds")
struct OverlayUIStateNoticeDwellTests {
  @Test
  func pastedClearsFastest() {
    #expect(OverlayUIState.pasted.noticeDwellSeconds == 0.8)
  }

  @Test
  func errorAndCopiedLingerLongEnoughToRead() {
    #expect(OverlayUIState.error(message: "boom").noticeDwellSeconds == 1.6)
    #expect(OverlayUIState.noTarget.noticeDwellSeconds == 1.6)
  }

  @Test
  func steadyStatesHaveNoDwell() {
    // Held for as long as the pipeline is in them — no auto-revert.
    #expect(OverlayUIState.idle.noticeDwellSeconds == nil)
    // `.connecting` in particular: a dwell would auto-revert the pill to idle
    // mid-press, dismissing it while the mic was still opening.
    #expect(OverlayUIState.connecting.noticeDwellSeconds == nil)
    #expect(OverlayUIState.recording.noticeDwellSeconds == nil)
    #expect(OverlayUIState.processing.noticeDwellSeconds == nil)
  }
}
