/// The shared tap/hold mode's slot: the one setting there was before each key
/// had its own (`TriggerKeyActivationStore`), and still the mode of any key
/// without one. Read through `TriggerKeyBindings`, which decodes it with
/// `TriggerActivation.fromPersisted` (unset or unknown is tap-or-hold); no
/// screen writes it any more, but an existing install's value is honoured.
public struct TriggerActivationStore {
  /// UserDefaults key holding the shared mode. Public so SwiftUI views can
  /// observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.triggerActivation.key }
}
