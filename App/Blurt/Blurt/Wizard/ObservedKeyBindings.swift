import BlurtEngine
import SwiftUI

/// Live-updating read of every trigger key's setting (`TriggerKeyBindings`),
/// for the views that show them: the Keys tab, the ready screen, the menu bar,
/// the permissions page and the Read Aloud tab.
///
/// Observes the four raw slots the bindings are built from through
/// `@AppStorage`, rather than reading `TriggerKeyBindings()` once, so a view
/// re-renders when the separate Settings window changes any of them. Each slot's unset default
/// (0, "") is "nothing persisted": the defaults belong to `TriggerKeyBindings`,
/// not to literals here.
@propertyWrapper
struct ObservedKeyBindings: DynamicProperty {
  @AppStorage(TriggerKeyStore.defaultsKey) private var boundKeyCode = 0
  @AppStorage(TriggerKeyStyleStore.defaultsKey) private var choicesRaw = ""
  @AppStorage(TriggerKeyActivationStore.defaultsKey) private var modesRaw = ""
  @AppStorage(TriggerActivationStore.defaultsKey) private var sharedModeRaw = ""

  var wrappedValue: TriggerKeyBindings {
    TriggerKeyBindings(
      boundKeyCode: boundKeyCode, choicesRaw: choicesRaw, modesRaw: modesRaw, sharedModeRaw: sharedModeRaw)
  }
}
