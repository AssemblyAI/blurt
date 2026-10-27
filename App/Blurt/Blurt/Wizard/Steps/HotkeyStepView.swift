import BlurtEngine
import SwiftUI

/// The dictation-key section of the setup/settings screen. Two menu pickers: which
/// lone modifier triggers dictation, and whether it activates by tap (toggle),
/// hold (push-to-talk), or both — plus a Key Styles row whose sheet gives each
/// trigger key its own style (or Off, for keys other than the bound one); changes
/// are persisted and pushed to the event tap immediately.
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

  // Observed so the Key Styles summary and the fn footer follow a change, and
  // decoded through the stores that own both encodings.
  @AppStorage(TriggerKeyStyleStore.defaultsKey) private var keyStylesRaw = ""
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""

  private var keyStyles: [TriggerKey: String] { TriggerKeyStyleStore.styles(decoding: keyStylesRaw) }

  @State private var isPresentingKeyStyles = false

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

  /// One "right ⌥: Casual" entry per trigger key, named as the sheet names it —
  /// the Edit… button's spoken summary. `changedOnly` keeps just the keys moved
  /// off their default (Off, or the main window's style for the bound key).
  private func keyStyleEntries(changedOnly: Bool) -> [String] {
    let profiles = StyleProfileStore().profiles(decoding: profilesRaw)
    let styles = keyStyles
    let bound = selection.wrappedValue
    return TriggerKey.allCases.compactMap { key in
      let choice = TriggerKeyStyleStore.choice(for: key, bound: bound, styles: styles, profiles: profiles)
      if changedOnly, choice == (key == bound ? TriggerKeyStyleStore.currentStyleID : "") { return nil }
      return "\(key.label): \(KeyStylesSheet.name(of: choice, profiles: profiles))"
    }
  }

  /// The Key Styles row's status: the keys set up beyond the default, or the main
  /// window's style when none are.
  private var keyStylesStatus: String {
    let changed = keyStyleEntries(changedOnly: true)
    return changed.isEmpty ? KeyStylesSheet.mainWindowName : changed.joined(separator: ", ")
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
      // A status and an "Edit…" button, like the API key row: the per-key pop-ups
      // live in a sheet, so the General pane grows one row rather than three.
      SettingRow(title: "Key Styles", systemImage: "textformat") {
        HStack(spacing: 8) {
          Text(keyStylesStatus)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
          Button("Edit…") { isPresentingKeyStyles = true }
            .accessibilityValue(keyStyleEntries(changedOnly: false).joined(separator: ", "))
            .accessibilityIdentifier(UITestIdentifiers.keyStylesButton)
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
    .sheet(isPresented: $isPresentingKeyStyles) {
      KeyStylesSheet(bound: selection.wrappedValue) { coordinator.dictationBindingChanged() }
    }
  }
}

/// Which style each trigger key dictates with, as a sheet from the Key Styles
/// row: one pop-up per key offering Off (except for the bound key, which
/// always dictates), the main window's style, Default, or a profile. Follows
/// `StyleProfileEditorSheet`'s shape — headline, explanation, content, and the
/// default action at the trailing edge — with only Done, since each choice is
/// written as it is made. While enhanced transcripts are off the styles are
/// disabled, as on the Styles pane; turning a key on or off still works.
private struct KeyStylesSheet: View {
  let bound: TriggerKey
  /// A key was turned on or off, so the tap must rebind (see `setStyle`).
  let onEnabledKeysChanged: () -> Void

  @Environment(\.dismiss) private var dismiss
  @AppStorage(TriggerKeyStyleStore.defaultsKey) private var keyStylesRaw = ""
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  static let offName = "Off"
  static let mainWindowName = "Same as main window"

  /// A choice's display name: Off, the main window's style, Default, or a profile.
  static func name(of choice: String, profiles: [StyleProfile]) -> String {
    switch choice {
    case "": offName
    case TriggerKeyStyleStore.currentStyleID: mainWindowName
    case StyleProfileStore.defaultStyleID: StyleProfileStore.defaultStyleName
    default: profiles.first { $0.id.uuidString == choice }?.name ?? mainWindowName
    }
  }

  var body: some View {
    let profiles = StyleProfileStore().profiles(decoding: profilesRaw)
    let styles = TriggerKeyStyleStore.styles(decoding: keyStylesRaw)
    VStack(alignment: .leading, spacing: 16) {
      header
      Form {
        Section {
          ForEach(TriggerKey.allCases, id: \.self) { key in
            PickerSettingRow(
              title: key.label, systemImage: "keyboard",
              accessibilityID: UITestIdentifiers.keyStylePicker(key.keyCode),
              selection: choice(for: key, styles: styles, profiles: profiles)
            ) {
              if key != bound { Text(Self.offName).tag("") }
              Text(Self.mainWindowName).tag(TriggerKeyStyleStore.currentStyleID)
              Group {
                Text(StyleProfileStore.defaultStyleName).tag(StyleProfileStore.defaultStyleID)
                ForEach(profiles) { profile in
                  Text(profile.name).tag(profile.id.uuidString)
                }
              }
              .disabled(!enhancedTranscripts)
            }
          }
        } footer: {
          if !enhancedTranscripts {
            Text("Turn on Enhanced transcripts to use styles.")
          }
        }
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .glassButtonStyleCompat(prominent: true)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier(UITestIdentifiers.keyStylesDone)
      }
      // Escape closes it too. The other sheets get that from their Cancel button;
      // every choice here is already saved, so the same shortcut rides a hidden one.
      .background {
        Button("Close") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .hidden()
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Key Styles")
        .font(.headline)
      Text("Each key can dictate with its own style, without changing the style selected in the main window.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// One key's pop-up: `""` is Off, otherwise a style id (see `TriggerKeyStyleStore`).
  private func choice(
    for key: TriggerKey, styles: [TriggerKey: String], profiles: [StyleProfile]
  ) -> Binding<String> {
    Binding(
      get: { TriggerKeyStyleStore.choice(for: key, bound: bound, styles: styles, profiles: profiles) },
      set: { newValue in
        // Through the store, which owns the encoding (see `HotkeyStepView.selection`).
        // Only a key turned on or off rebinds the tap; a style is read at the next press.
        if TriggerKeyStyleStore().setStyle(newValue, for: key) { onEnabledKeysChanged() }
      })
  }
}
