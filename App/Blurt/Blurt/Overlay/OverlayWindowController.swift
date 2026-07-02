import AppKit
import BlurtEngine
import Observation
import SwiftUI

@MainActor
@Observable
final class OverlayBridge {
  var state: OverlayUIState = .idle
  /// The latest mic loudness, 0...1 (MicCapture.linearLevel). The overlay's
  /// voice bars track this current value — there is no scrolling history.
  var level: Float = 0

  func pushLevel(_ value: Float) {
    // `value` is already a fixed 0...1 scale from the recorder's dBFS meter
    // (MicCapture.linearLevel) — store the latest as-is. (No auto-gain
    // normalizing to a running peak: that stretched sustained speech to full.)
    level = min(1, max(0, value))
  }
}

private struct OverlayHost: View {
  var bridge: OverlayBridge
  var body: some View {
    OverlayView(state: bridge.state, level: bridge.level)
  }
}

@MainActor
final class OverlayWindowController {
  private static let customOriginXKey = "BlurtOverlayCustomOriginX"
  private static let customOriginYKey = "BlurtOverlayCustomOriginY"
  // The panel is sized larger than the visible pill so SwiftUI's drop shadow
  // (see `OverlayView`'s `.shadow`, which documents staying within
  // `shadowMargin`) has room to render without being clipped by the window's
  // contentRect — especially around the capsule's rounded ends, where the
  // shadow extends furthest from the pill body.
  static let pillSize = CGSize(width: 168, height: 28)
  static let shadowMargin: CGFloat = 16
  private static let panelSize = CGSize(
    width: pillSize.width + shadowMargin * 2,
    height: pillSize.height + shadowMargin * 2)

  private let panel: NSPanel
  private let hosting: NSHostingView<OverlayHost>
  private let bridge = OverlayBridge()
  private var suppressOriginPersist = false

  // How long a transient notice (error flash / "copied" notice) lingers before
  // settling back to idle.
  private static let errorFlashSeconds: Double = 1.6
  private var errorRevertTask: Task<Void, Never>?

  // Token for the block-based didMove observer so `deinit` can deregister it.
  // `nonisolated(unsafe)` because the nonisolated deinit reads it: it's written
  // once in init and read once in deinit, both with exclusive access, so the
  // unchecked access is sound.
  private nonisolated(unsafe) var didMoveObserver: (any NSObjectProtocol)?

  init() {
    let host = OverlayHost(bridge: bridge)
    self.hosting = NSHostingView(rootView: host)
    self.hosting.wantsLayer = true
    self.hosting.layer?.backgroundColor = .clear
    self.panel = FloatingPanel.make(
      size: Self.panelSize,
      collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary],
      contentView: hosting
    )
    panel.isMovable = true
    panel.isMovableByWindowBackground = true

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
  /// error-flash revert) mirrors the `[weak self]` care above and documents that
  /// the registrations are owned, not leaked.
  deinit {
    if let didMoveObserver {
      NotificationCenter.default.removeObserver(didMoveObserver)
    }
    errorRevertTask?.cancel()
  }

  func show(state: OverlayUIState) {
    // Any explicit state change supersedes a pending error-flash revert: a new
    // press while the red pill is up should win, not get stomped back to idle.
    errorRevertTask?.cancel()
    errorRevertTask = nil

    // Idle means "no dictation happening" — the pill rides the pipeline and is
    // hidden at rest, so fade it out. The displayed state is left untouched so
    // the capsule keeps its last content (waveform/dots/red error) through the
    // fade rather than snapping to empty; `setVisible` resets it once hidden.
    if case .idle = state {
      setVisible(false)
      return
    }

    bridge.state = state
    // The red error flash and the neutral "copied" notice are both transient: the
    // pill is otherwise only up during active dictation, so they linger briefly to
    // be read, then settle back to idle. Announce them for VoiceOver since this
    // non-activating panel never gets focus (HIG: Accessibility / Feedback).
    if state.isTransientNotice {
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: state.accessibilityLabel,
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
      errorRevertTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(Self.errorFlashSeconds))
        guard let self, !Task.isCancelled else { return }
        self.show(state: .idle)
      }
    }
    setVisible(true)
  }

  /// Hides the pill immediately, without the fade. Called when the app drops out
  /// of its fully-configured state (a permission revoked, the key cleared, the
  /// shortcut unbound) so the pill is only ever on screen while dictation can
  /// actually work.
  func hide() {
    errorRevertTask?.cancel()
    errorRevertTask = nil
    // Settle the content even when the panel is already off screen (the pill
    // may have been hidden mid-notice).
    bridge.state = .idle
    guard panel.isVisible else { return }
    dismissPanel()
  }

  /// Shared final step of every dismiss path: order the panel out, restore full
  /// alpha for the next show, and settle the pill content back to idle.
  private func dismissPanel() {
    panel.orderOut(nil)
    panel.alphaValue = 1
    bridge.state = .idle
  }

  /// Drives the pill on/off screen, fading unless Reduce Motion is on. Idempotent
  /// and re-entrant: a key-down during the fade-out re-targets alpha back to 1,
  /// and the in-flight fade's completion only orders the panel out if it actually
  /// reached transparent — so a quick hide→show never strands a hidden panel.
  private func setVisible(_ visible: Bool) {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if visible {
      if !panel.isVisible {
        reposition()
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
      }
      if reduceMotion {
        panel.alphaValue = 1
      } else {
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.2
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
        { ctx in
          ctx.duration = 0.2
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
    let frame = panel.frame
    let origin: NSPoint
    if let custom = storedCustomOrigin() {
      origin = clamp(point: custom, size: frame.size, into: screen.visibleFrame)
    } else {
      origin = NSPoint(
        x: screen.visibleFrame.midX - frame.width / 2,
        y: screen.visibleFrame.minY + 80 - Self.shadowMargin)
    }
    suppressOriginPersist = true
    panel.setFrameOrigin(origin)
    suppressOriginPersist = false
  }

  private func handleDidMove() {
    guard !suppressOriginPersist else { return }
    let origin = panel.frame.origin
    UserDefaults.standard.set(Double(origin.x), forKey: Self.customOriginXKey)
    UserDefaults.standard.set(Double(origin.y), forKey: Self.customOriginYKey)
  }

  private func storedCustomOrigin() -> NSPoint? {
    let defaults = UserDefaults.standard
    guard
      let x = defaults.object(forKey: Self.customOriginXKey) as? Double,
      let y = defaults.object(forKey: Self.customOriginYKey) as? Double
    else { return nil }
    return NSPoint(x: x, y: y)
  }

  private func clamp(point: NSPoint, size: CGSize, into rect: NSRect) -> NSPoint {
    let maxX = rect.maxX - size.width
    let maxY = rect.maxY - size.height
    return NSPoint(
      x: min(max(point.x, rect.minX), maxX),
      y: min(max(point.y, rect.minY), maxY))
  }
}
