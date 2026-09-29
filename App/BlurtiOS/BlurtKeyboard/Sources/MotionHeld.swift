import SwiftUI

/// Whether the keyboard's continuous motion — the ring's sweep, the meter's
/// idle wave, the orb's fluid and grain, the caret's blink — is held at time
/// zero. Reduce Motion holds it for the user; the gallery's
/// `-BlurtGalleryStill` holds it for a capture, so the same state is the same
/// pixels every time (DESIGN.md › Figma). The system value is read-only, so
/// this is the switch the views combine it with.
private struct KeyboardMotionHeldKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var keyboardMotionHeld: Bool {
    get { self[KeyboardMotionHeldKey.self] }
    set { self[KeyboardMotionHeldKey.self] = newValue }
  }
}
