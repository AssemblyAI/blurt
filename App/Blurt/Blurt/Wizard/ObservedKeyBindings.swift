import BlurtEngine
import SwiftUI

/// Live-updating read of every trigger key's setting (`TriggerKeyBindings`),
/// for the views that show them: the Keys tab, the ready screen, the menu bar,
/// the permissions page and the Read Aloud tab.
///
/// Observes the three raw slots the bindings are built from through
/// `@AppStorage`, rather than reading `TriggerKeyBindings()` once, so a view
/// re-renders when the separate Settings window changes any of them. Each slot's unset default
/// (0, "") is "nothing persisted": the defaults belong to `TriggerKeyBindings`,
/// not to literals here.
@propertyWrapper
struct ObservedKeyBindings: DynamicProperty {
  @AppStorage(TriggerKeyStore.defaultsKey)
  private var boundKeyCode = 0
  @AppStorage(TriggerKeyStyleStore.defaultsKey)
  private var choicesRaw = ""
  @AppStorage(TriggerActivationStore.defaultsKey)
  private var activationRaw = ""

  // Read through the property wrapper's syntax, which the analyzer doesn't count as a use.
  // swiftlint:disable:next unused_declaration
  var wrappedValue: TriggerKeyBindings {
    TriggerKeyBindings(boundKeyCode: boundKeyCode, choicesRaw: choicesRaw, activationRaw: activationRaw)
  }
}
