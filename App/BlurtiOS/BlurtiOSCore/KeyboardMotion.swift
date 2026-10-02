import BlurtEngine
import Foundation

/// The redraw cap for the keyboard's continuous motion — the sheen, the
/// meter's idle wave, the glints. The Mac pill reads the same number from
/// the engine: the level feed moves at this cadence, so drawing faster only
/// burns the keyboard's tight energy and memory budget.
package let keyboardAnimationInterval = MicCapture.meterIntervalSeconds
