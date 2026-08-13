import AppKit
import BlurtEngine
import Observation
import SwiftUI

@Observable
final class OverlayBridge {
  var state: OverlayUIState = .idle
  /// The latest mic loudness, 0...1 (MicCapture.linearLevel). The overlay's
  /// voice bars track this current value — there is no scrolling history.
  var level: Float = 0

  func pushLevel(_ value: Float) {
    // `value` arrives on the fixed 0...1 scale `MicCaptureProtocol.levels`
    // documents (MicCapture.linearLevel). Clamp once here — the single seam where
    // any capture implementation crosses into the view layer — so the bars can
    // trust the range instead of re-checking it. (No auto-gain normalizing to a
    // running peak: that stretched sustained speech to full.)
    let clamped = min(1, max(0, value))
    // @Observable invalidates on assignment, not on change, and `linearLevel` is
    // floored so room ambient maps to exactly 0 — without this guard every silent
    // tick would rebuild the whole bar row 20×/s with an unchanged value.
    guard clamped != level else { return }
    level = clamped
  }
}

final class OverlayWindowController {
  // The panel is sized larger than the visible pill so SwiftUI's drop shadow
  // (see `OverlayView`'s `.shadow`, which documents staying within
  // `shadowMargin`) has room to render without being clipped by the window's
  // contentRect — especially around the capsule's rounded ends, where the
  // shadow extends furthest from the pill body.
  static let pillSize = CGSize(width: 168, height: 28)
  // Transparent breathing room around the pill so the drop shadow's *full*
  // Gaussian falloff renders before the panel's contentRect clips it. A SwiftUI
  // `.shadow(radius:)` spreads visibly to roughly 2× the radius (not `radius`
  // itself) plus the y offset, so this must comfortably exceed the pill's
  // `radius: 10, y: 3` shadow — otherwise the falloff is cut off mid-gradient and
  // reads as a hard line around the pill rather than a soft shadow.
  static let shadowMargin: CGFloat = 28
  // The pill/panel size relationship is the engine's, next to the `panelOrigin`
  // that backs the placement clearance off by the same margin — so a change to
  // `shadowMargin` is checked on both sides rather than only one.
  private static let panelSize = OverlayPlacement.panelSize(
    pillSize: pillSize, shadowMargin: shadowMargin)

  private let panel: NSPanel
  private let hosting: NSHostingView<OverlayView>
  private let bridge = OverlayBridge()
  private var suppressOriginPersist = false

  // The revert timer for a transient notice; its dwell comes from the engine
  // (`OverlayUIState.noticeDwellSeconds`, unit-tested there).
  private var errorRevertTask: Task<Void, Never>?

  // Holds the `.connecting` VoiceOver announcement until the bring-up has
  // persisted past `ConnectingLabel.revealDelay` — the same hold the label
  // itself applies. A fast (wired/built-in) route resolves within the delay,
  // cancels this, and stays silent all the way to the start chime; only a real
  // (Bluetooth-length) wait gets spoken. Without it, VoiceOver users had no
  // non-visual feedback at all during a bring-up: announcements fired only for
  // the dwell notices, and this non-activating panel never takes focus.
  private var connectingAnnounceTask: Task<Void, Never>?

  // The pill fades in fast — the appear is tied to the user's keypress, so a snappy
  // ramp reads as instant response — but fades out gently. Asymmetric on purpose.
  private static let appearFadeDuration: Double = 0.08
  private static let dismissFadeDuration: Double = 0.2

  // Token for the block-based didMove observer so `deinit` can deregister it.
  // `nonisolated(unsafe)` because the nonisolated deinit reads it: it's written
  // once in init and read once in deinit, both with exclusive access, so the
  // unchecked access is sound.
  private nonisolated(unsafe) var didMoveObserver: (any NSObjectProtocol)?

  init() {
    self.hosting = NSHostingView(rootView: OverlayView(bridge: bridge))
    self.hosting.wantsLayer = true
    self.hosting.layer?.backgroundColor = .clear
    self.panel = FloatingPanel.make(
      size: Self.panelSize,
      collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary],
      contentView: hosting
    )
    panel.isMovable = true
    panel.isMovableByWindowBackground = true
    // This controller owns the pill's fades (see `setVisible`), so AppKit must not
    // add its own. Left at `.default`, AppKit infers `.utilityWindow` for an
    // NSPanel — which fades on `orderOut` — so `dismissPanel()` ran a *second*
    // fade after the alpha ramp had already finished, with full alpha restored and
    // the content settled to `.idle`: the red "Try again" body faded out, then an
    // empty capsule reappeared and faded out again. `.none` makes ordering out
    // immediate, so the alpha ramp is the only fade the user sees.
    panel.animationBehavior = .none

    // `queue: nil` so the block runs synchronously on the posting thread —
    // always main for window moves, hence the `assumeIsolated`. `queue: .main`
    // would bounce delivery through an OperationQueue hop, running the block a
    // run-loop pass *after* `reposition()` has already cleared
    // `suppressOriginPersist`, so the programmatic placement would be persisted
    // as if the user had dragged the pill there.
    self.didMoveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification,
      object: panel,
      queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleDidMove()
      }
    }
  }

  /// OverlayWindowController lives for the whole app session, so this never runs
  /// in practice — but tearing the observer down (and cancelling any pending
  /// error-flash revert or connecting announcement) mirrors the `[weak self]`
  /// care above and documents that the registrations are owned, not leaked.
  deinit {
    if let didMoveObserver {
      NotificationCenter.default.removeObserver(didMoveObserver)
    }
    errorRevertTask?.cancel()
    connectingAnnounceTask?.cancel()
  }

  func show(state: OverlayUIState) {
    // Any explicit state change supersedes a pending error-flash revert: a new
    // press while the red pill is up should win, not get stomped back to idle.
    errorRevertTask?.cancel()
    errorRevertTask = nil
    // Likewise a pending connecting announcement: once the state has moved on
    // (to `.recording`, or a failure), announcing "Connecting" would be stale —
    // and on a fast bring-up this cancel is what keeps the pill silent.
    connectingAnnounceTask?.cancel()
    connectingAnnounceTask = nil

    // Idle means "no dictation happening" — the pill rides the pipeline and is
    // hidden at rest, so fade it out. The displayed state is left untouched so
    // the capsule keeps its last content (waveform/dots/red error) through the
    // fade rather than snapping to empty; `setVisible` resets it once hidden.
    if case .idle = state {
      setVisible(false)
      return
    }

    // Guard the assignment the way `OverlayBridge.pushLevel` does: `@Observable`
    // invalidates on assignment, not on change, and `.transcribing` and `.injecting`
    // both project to `.processing` — so every dictation re-evaluated the whole
    // `OverlayView` body (capsule fill, border, shadow, a fresh `TimelineView`) for
    // a value that hadn't moved. The notice handling below stays outside the guard:
    // a repeated notice still has to announce and re-arm its revert.
    if bridge.state != state {
      bridge.state = state
    }
    // The mic bring-up gets the same VoiceOver treatment as the dwell notices
    // below — this panel never takes focus, so an announcement is the only
    // non-visual channel — but held for the label's reveal delay first (see
    // `connectingAnnounceTask`): a fast route flips to `.recording` within the
    // delay and goes straight to the start chime.
    if case .connecting = state {
      connectingAnnounceTask = Task {
        try? await Task.sleep(for: ConnectingLabel.revealDelay)
        guard !Task.isCancelled else { return }
        NSAccessibility.post(
          element: NSApp as Any,
          notification: .announcementRequested,
          userInfo: [
            .announcement: state.accessibilityLabel,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
          ])
      }
    }
    // The red error flash and the neutral "copied" notice are both transient: the
    // pill is otherwise only up during active dictation, so they linger briefly to
    // be read, then settle back to idle. Announce them for VoiceOver since this
    // non-activating panel never gets focus (HIG: Accessibility / Feedback).
    if let dwell = state.noticeDwellSeconds {
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: state.accessibilityLabel,
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
      errorRevertTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(dwell))
        guard let self, !Task.isCancelled else { return }
        self.show(state: .idle)
      }
    }
    setVisible(true)
  }

  /// Hides the pill immediately, without the fade. Called when the app drops out
  /// of its fully-configured state (a permission revoked, the key cleared).
  ///
  /// This hides the pill; it does **not** disarm the trigger — the `CGEventTap`
  /// stays installed, so a press while not-ready still runs and the pill comes back
  /// to report the failure. That's deliberate: tearing the tap down would depend on
  /// `ensureRunning()` succeeding again to restore dictation, and a tap that failed
  /// to reinstall is a far worse failure than an error flash. `WizardController`
  /// surfaces the setup window on the same not-ready edge, which is what actually
  /// routes the user to the fix.
  func hide() {
    errorRevertTask?.cancel()
    errorRevertTask = nil
    connectingAnnounceTask?.cancel()
    connectingAnnounceTask = nil
    guard panel.isVisible else {
      // Still settle the content when the panel is already off screen (the pill
      // may have been hidden mid-notice) — `dismissPanel` would have done it.
      settleContent()
      return
    }
    dismissPanel()
  }

  /// Shared final step of every dismiss path: order the panel out, restore full
  /// alpha for the next show, and settle the pill content back to idle.
  private func dismissPanel() {
    panel.orderOut(nil)
    panel.alphaValue = 1
    settleContent()
  }

  /// Resets the pill to its at-rest content — **without** animating.
  ///
  /// `OverlayView` carries an implicit `.animation(value: state)`, so a plain
  /// assignment here would start a 0.15 s cross-fade (the notice content out, the
  /// red error body back to the neutral fill) at the exact moment the pill leaves
  /// the screen: an empty capsule still animating after the dismiss. The pill's
  /// only fade is the alpha ramp in `setVisible`, so this settle is instantaneous.
  private func settleContent() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      bridge.state = .idle
      // Clear the level too, or the pill's next appearance renders its bars at the
      // PREVIOUS dictation's loudness until the first new meter tick (~50 ms)
      // replaces it — a one-frame "already talking" flash at the start of every
      // dictation. `MicCapture.stop()` cancels the meter task without a final zero
      // yield, so nothing else resets this.
      bridge.level = 0
    }
  }

  /// Drives the pill on/off screen, fading unless Reduce Motion is on. Idempotent
  /// and re-entrant: a key-down during the fade-out re-targets alpha back to 1,
  /// and the in-flight fade's completion only orders the panel out if it actually
  /// reached transparent — so a quick hide→show never strands a hidden panel.
  private func setVisible(_ visible: Bool) {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if visible {
      // Already up and fully opaque: nothing to ramp. Without this, each phase
      // change during one dictation spun up an `NSAnimationContext` group animating
      // alpha from 1 to 1 (~3 per dictation). A panel mid-fade-out is visible with
      // alpha below 1, so it still falls through and re-targets alpha to 1 — the
      // re-entrancy the doc comment above promises.
      if panel.isVisible, panel.alphaValue >= 1 { return }
      if !panel.isVisible {
        reposition()
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
      }
      if reduceMotion {
        panel.alphaValue = 1
      } else {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = Self.appearFadeDuration
          panel.animator().alphaValue = 1
        }
      }
    } else {
      guard panel.isVisible else { return }
      if reduceMotion {
        dismissPanel()
        return
      }
      NSAnimationContext.runAnimationGroup(
        { context in
          context.duration = Self.dismissFadeDuration
          panel.animator().alphaValue = 0
        },
        completionHandler: { [weak self] in
          // NSAnimationContext completion handlers run on the main thread.
          MainActor.assumeIsolated {
            guard let self, self.panel.alphaValue < 0.01 else { return }
            self.dismissPanel()
          }
        })
    }
  }

  func pushLevel(_ value: Float) {
    bridge.pushLevel(value)
  }

  private func reposition() {
    guard let screen = NSScreen.main else { return }
    // All the placement policy — default bottom-center, the clearance, the
    // pill-vs-panel shadow correction, and clamping a stale dragged origin back on
    // screen — is the engine's `OverlayPlacement`, unit-tested there. This passes
    // only what the shell owns: the panel size, the screen, and the shadow inset.
    let origin = OverlayPlacement.panelOrigin(
      panelSize: panel.frame.size,
      visibleFrame: screen.visibleFrame,
      customOrigin: Self.originStore.origin,
      shadowMargin: Self.shadowMargin)
    suppressOriginPersist = true
    panel.setFrameOrigin(origin)
    suppressOriginPersist = false
  }

  private func handleDidMove() {
    guard !suppressOriginPersist else { return }
    Self.originStore.origin = panel.frame.origin
  }

  /// Persistence for the dragged origin lives in the engine next to the clamping
  /// it feeds, and is registered in `PersistedSettings.allDefaultsKeys` so reset
  /// sweeps clear it.
  private static let originStore = OverlayOriginStore()
}
