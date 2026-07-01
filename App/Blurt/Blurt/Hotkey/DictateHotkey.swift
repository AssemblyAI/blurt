import BlurtEngine

/// Display strings for the current dictation trigger key, read from the
/// persisted `TriggerKeyStore`. Used by the overlay pill, the ready-screen
/// keycaps, and onboarding footers.
@MainActor
enum DictateHotkey {
  static var triggerKey: TriggerKey { TriggerKeyStore().triggerKey }

  /// Inline form, e.g. "right ⌘".
  static var label: String { triggerKey.label }
}
