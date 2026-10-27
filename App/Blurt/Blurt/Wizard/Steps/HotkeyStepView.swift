import BlurtEngine
import SwiftUI

/// The dictation-key section of the setup/settings screen. Menu pickers for which
/// lone modifier triggers dictation, whether it activates by tap (toggle), hold
/// (push-to-talk), or both, and — one row per trigger key — the style each key
/// dictates with, or Off for a key other than the bound one; changes are
/// persisted and pushed to the event tap immediately.
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

  // Observed so the per-key rows follow a style added or deleted in the Styles
  // pane, and decoded through the stores that own both encodings.
  @AppStorage(TriggerKeyStyleStore.defaultsKey) private var keyStylesRaw = ""
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""

  private var keyStyles: [TriggerKey: String] { TriggerKeyStyleStore.styles(decoding: keyStylesRaw) }

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

  /// One key's row: `""` is Off, otherwise a style id (see `TriggerKeyStyleStore`).
  private func keyStyle(_ key: TriggerKey, profiles: [StyleProfile]) -> Binding<String> {
    Binding(
      get: {
        TriggerKeyStyleStore.choice(
          for: key, bound: selection.wrappedValue, styles: keyStyles, profiles: profiles)
      },
      set: { newValue in
        // Through the store for the same reason as `selection` above.
        let store = TriggerKeyStyleStore()
        var styles = store.styles
        styles[key] = newValue.isEmpty ? nil : newValue
        store.styles = styles
        coordinator.dictationBindingChanged()
      })
  }

  /// One row per trigger key: the style a press of it dictates with — the main
  /// window's current one, Default, or a profile — or Off. The bound key always
  /// dictates, so only the others offer Off.
  @ViewBuilder private var keyStyleRows: some View {
    let profiles = StyleProfileStore().profiles(decoding: profilesRaw)
    ForEach(TriggerKey.allCases, id: \.self) { key in
      PickerSettingRow(
        title: key.fullName, systemImage: "textformat",
        accessibilityID: UITestIdentifiers.keyStylePicker(key.keyCode),
        selection: keyStyle(key, profiles: profiles)
      ) {
        if key != selection.wrappedValue { Text("Off").tag("") }
        Text("Current style").tag(TriggerKeyStyleStore.currentStyleID)
        Text(StyleProfileStore.defaultStyleName).tag(StyleProfileStore.defaultStyleID)
        ForEach(profiles) { profile in
          Text(profile.name).tag(profile.id.uuidString)
        }
      }
    }
  }

  private static let keyboardSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

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
      keyStyleRows
    } header: {
      Text("Shortcut")
    } footer: {
      // The engine owns the wording (`TriggerActivation.guidance`), so the hint
      // always describes the mode the gate will actually apply. Each variant is
      // no longer than the tap-or-hold sentence shipped here before the picker
      // existed, so the footer never grows the pane.
      Text(TriggerActivation.fromPersisted(activationRaw).guidance)
      // Say so when Blurt has changed a system setting on the user's behalf
      // (`GlobeKeyOverride`), so a 🌐 key that stopped opening emoji isn't a mystery.
      // That write only lands at the next log-in, so link to the pane that
      // applies it now.
      if TriggerKeyStyleStore.enabledKeys(bound: selection.wrappedValue, styles: keyStyles).contains(.function) {
        Text(
          "While fn is a dictation key, macOS’s “Press 🌐 key to” is set to Do Nothing "
            + "from your next log-in. To stop 🌐 firing sooner, set it in Keyboard Settings.")
        Link("Open Keyboard Settings…", destination: Self.keyboardSettingsURL)
      }
    }
  }
}
