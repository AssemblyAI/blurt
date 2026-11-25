import BlurtEngine
import CoreFoundation
import Observation

@Observable
final class OverlayBridge {
  var state: OverlayUIState = .idle
  /// The latest mic loudness, 0...1 (MicCapture.linearLevel). The overlay's
  /// voice bars track this current value — there is no scrolling history.
  var level: Float = 0
  /// The capsule's current width: `OverlayWindowController.pillSize.width`,
  /// except while a notice that writes its reason on the pill is up (see
  /// `OverlayWindowController.pillWidth(for:)`).
  var pillWidth: CGFloat = OverlayWindowController.pillSize.width
  /// Whether the view cross-fades its latest state change. False for a change
  /// that also resizes the pill: the panel and the capsule can't move in step,
  /// so that swap happens in one step under a fade of the whole panel instead.
  /// A flag the view reads rather than a `withTransaction`, because this
  /// `@Observable` reaches the view in a later update, after any transaction
  /// set here has ended.
  var animatesStateChange = true

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
    guard clamped != level else {
      return
    }
    level = clamped
  }
}
