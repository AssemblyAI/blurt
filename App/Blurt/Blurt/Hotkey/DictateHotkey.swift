import BlurtEngine

/// Display strings for the current dictation trigger key, read from the
/// persisted `TriggerKeyStore`. For one-shot reads only (e.g. the permissions
/// step's description); views that must re-render live on a Settings change
/// read the raw keycode via `@AppStorage` + `TriggerKey.fromPersisted` instead.
enum DictateHotkey {
  static var triggerKey: TriggerKey { TriggerKeyStore().triggerKey }

  /// Inline form, e.g. "right ⌘".
  static var label: String { triggerKey.label }
}
