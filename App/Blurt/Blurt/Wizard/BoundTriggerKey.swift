import BlurtEngine
import SwiftUI

/// Live-updating read of the bound dictation trigger key, for the views that
/// only *display* it ("Tap or hold right ⌘ to blurt").
///
/// Wraps the `@AppStorage` + `TriggerKey.fromPersisted` pair that three views —
/// the ready screen, the menu bar menu, and the permissions footer — each spelled
/// out, along with a restated `TriggerKey.rightCommand.rawValue` default that
/// `fromPersisted` already owns (an unset default reads as 0, which it maps to
/// right ⌘). Reading the raw keycode through `@AppStorage`, rather than calling
/// `TriggerKeyStore()` once, is what makes these views re-render when the key is
/// rebound in the separate Settings window.
///
/// A `DynamicProperty` rather than a `View` because two of the three call sites
/// need the value inside a larger sentence, not a `Text` of its own.
@propertyWrapper
struct BoundTriggerKey: DynamicProperty {
  @AppStorage(TriggerKeyStore.defaultsKey) private var keyCode = 0

  var wrappedValue: TriggerKey { TriggerKey.fromPersisted(keyCode) }
}
