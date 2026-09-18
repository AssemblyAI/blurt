import BlurtEngine
import SwiftUI

/// The dictation-key section of the setup/settings screen. Two menu pickers: which
/// lone modifier triggers dictation, and whether it activates by tap (toggle),
/// hold (push-to-talk), or both; changes are persisted and pushed to the event
/// tap immediately.
struct HotkeyStepView: View {
  var coordinator: AppCoordinator

  // `0` is "no keycode persisted", not a default binding: the unset default belongs
  // to `TriggerKey.fromPersisted` (below), which maps any unknown keycode to right
  // ⌘. Restating `TriggerKey.rightCommand.rawValue` here would give the empty slot
  // two answers, and this one would win for an unset key — so a change to the
  // engine's default would leave this picker showing the old binding while the
  // ready screen and menu bar showed the new one. Matches `@BoundTriggerKey`.
  @AppStorage(TriggerKeyStore.defaultsKey) private var triggerKeyCode = 0

  // Same rule for the activation half: "" is "nothing persisted", and the unset
  // default belongs to `TriggerActivation.fromPersisted`, not a literal here.
  @AppStorage(TriggerActivationStore.defaultsKey) private var activationRaw = ""

  private var selection: Binding<TriggerKey> {
    Binding(
      get: {
        TriggerKey.fromPersisted(triggerKeyCode)
      },
      set: { newValue in
        // Write through the store, not the raw `@AppStorage` slot: the store owns
        // how a `TriggerKey` is encoded, and `@AppStorage` is here to *observe* the
        // key so this view re-renders (it picks up the store's external write).
        // Assigning `triggerKeyCode` directly left `TriggerKeyStore`'s setter with
        // no production caller, so a change to the encoding — versioning the key,
        // storing the case name, a migration — would keep `swift test` green while
        // the picker silently kept writing the old form.
        TriggerKeyStore().triggerKey = newValue
        coordinator.dictationBindingChanged()
      })
  }

  private var activation: Binding<TriggerActivation> {
    Binding(
      get: {
        TriggerActivation.fromPersisted(activationRaw)
      },
      set: { newValue in
        // Write through the store for the same reason as `selection` above.
        TriggerActivationStore().activation = newValue
        coordinator.dictationBindingChanged()
      })
  }

  var body: some View {
    Section {
      PickerSettingRow(
        title: "Dictation key", systemImage: "keyboard",
        accessibilityID: UITestIdentifiers.hotkeyPicker, selection: selection
      ) {
        ForEach(TriggerKey.allCases, id: \.self) { key in
          Text(key.label).tag(key)
        }
      }
      PickerSettingRow(
        title: "Activation", systemImage: "hand.tap",
        accessibilityID: UITestIdentifiers.activationPicker, selection: activation
      ) {
        ForEach(TriggerActivation.allCases, id: \.self) { mode in
          Text(mode.label).tag(mode)
        }
      }
    } header: {
      Text("Shortcut")
    } footer: {
      // The engine owns the wording (`TriggerActivation.guidance`), so the hint
      // always describes the mode the gate will actually apply. Each variant is
      // no longer than the tap-or-hold sentence shipped here before the picker
      // existed, so the footer never grows the pane.
      Text(TriggerActivation.fromPersisted(activationRaw).guidance)
    }
  }
}
