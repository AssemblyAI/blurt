import BlurtEngine
import Foundation

/// The redraw cap for the keyboard's continuous motion — the ring's sweep, the
/// meter's idle wave. The Mac pill reads the same number from the engine: the
/// level feed moves at this cadence, so drawing faster only burns the
/// keyboard's tight energy and memory budget.
let keyboardAnimationInterval = MicCapture.meterIntervalSeconds

/// The keyboard's clocks, in one place.
nonisolated enum KeyboardMotion {
  /// One turn of the ring every 1.6 s: the Mac's cadence.
  static let ringPeriod = DesignTokens.Motion.ringPeriod
}
