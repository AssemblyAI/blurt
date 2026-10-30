import BlurtEngine
import SwiftUI

/// The Keys tab: per trigger key, an action pop-up — Off, dictate (with the
/// main window's style, no custom style, or a profile), read the selection
/// aloud, or ask about it — and whether it's tapped, held, or either. A pane
/// of its own after General, so every key's choice is in view and General
/// stays short enough for a small display. Changes are persisted and pushed to
/// the event tap immediately. How read-aloud sounds is its own tab
/// (`ReadAloudSettingsTab`).
///
/// Reads go through `TriggerKeyBindings` (one decode per render) and writes
/// through the stores, never the raw `@AppStorage` slots: the stores own how a
/// choice and a mode are encoded, and the bound-key rule — taking the only
/// dictating key off dictation is refused, and taking the bound key off it
/// moves the binding first — lives in `TriggerKeyStyleStore.setChoice`, where
/// it is tested. Assigning a raw slot directly would leave the store's write
/// with no production caller, so an encoding change would keep `swift test`
/// green while this view kept writing the old form.
struct KeysSettingsTab: View {
  let coordinator: AppCoordinator

  @ObservedKeyBindings private var bindings
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  private static let keyboardSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

  /// Shared widths keep the column headings aligned with the native pickers.
  private static let actionWidth: CGFloat = 150
  private static let activationWidth: CGFloat = 108

  /// Each row's icon: the key's own symbol.
  static func symbol(for key: TriggerKey) -> String {
    switch key {
    case .rightCommand, .leftCommand: "command"
    case .rightOption, .leftOption: "option"
    case .leftControl: "control"
    case .function: "globe"
    }
  }

  var body: some View {
    let bindings = bindings
    let profiles = StyleProfileStore().profiles(decoding: profilesRaw)
    let dictating = bindings.dictatingKeys
    SettingsPane {
      Section {
        ForEach(TriggerKey.allCases, id: \.self) { key in
          row(for: key, bindings: bindings, profiles: profiles, isOnlyDictatingKey: dictating == [key])
        }
      } header: {
        HStack(spacing: 8) {
          Text("Key")
          Spacer(minLength: 12)
          Text("Action")
            .frame(width: Self.actionWidth, alignment: .trailing)
          Text("Activation")
            .frame(width: Self.activationWidth, alignment: .trailing)
        }
      } footer: {
        Text("Dictate uses your current writing style. Choose No custom style to use only Blurt’s standard cleanup.")
        // The only dictating key's other choices are disabled; say why.
        if let only = dictating.first, dictating.count == 1 {
          Text("To reassign \(only.spokenName), set another key to Dictate first.")
        }
        if !enhancedTranscripts {
          Text(StylesInertNotice.settingsText)
        }
        // `GlobeKeyOverride` turns off macOS's own 🌐 action while fn does
        // anything, but that write only lands at the next log-in, so until then
        // fn double-fires. Lead with that symptom rather than the setting's name,
        // and link to the pane that applies the change now.
        if bindings.enabledKeys.contains(.function) {
          Text(
            "Until you next log in, pressing fn may also open the emoji picker or Apple "
              + "Dictation. To fix that now, open Keyboard Settings and set “Press 🌐 key to” "
              + "to Do Nothing.")
          Link("Open Keyboard Settings…", destination: Self.keyboardSettingsURL)
        }
      }
    }
  }

  private func row(
    for key: TriggerKey, bindings: TriggerKeyBindings, profiles: [StyleProfile], isOnlyDictatingKey: Bool
  ) -> some View {
    let action = bindings.action(for: key)
    return SettingRow(title: key.spokenName, systemImage: Self.symbol(for: key)) {
      HStack(spacing: 8) {
        // Every item names its action on its own, since a closed pop-up shows
        // only the one chosen, without the menu's dividers around it. The
        // hidden titles are what VoiceOver reads for each pop-up. The only
        // dictating key offers only dictation — left out rather than disabled,
        // since a menu pop-up doesn't reliably disable single items; the
        // footer says why.
        Picker("Action for \(key.fullName)", selection: choice(for: key, bindings: bindings, profiles: profiles)) {
          if !isOnlyDictatingKey {
            Text("Off").tag(TriggerKeyChoice.off)
            Divider()
          }
          Text("Dictate").tag(TriggerKeyChoice.dictate)
          Group {
            Text("Dictate: No custom style").tag(TriggerKeyChoice.dictate(style: StyleProfileStore.defaultStyleID))
            ForEach(profiles) { profile in
              Text("Dictate: \(profile.name)").tag(TriggerKeyChoice.dictate(style: profile.id.uuidString))
            }
          }
          .disabled(!enhancedTranscripts)
          if !isOnlyDictatingKey {
            Divider()
            Text(KeyActionName.readAloud).tag(TriggerKeyChoice.readAloud)
            Text(KeyActionName.ask).tag(TriggerKeyChoice.ask)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .lineLimit(1)
        .frame(width: Self.actionWidth, alignment: .trailing)
        .accessibilityIdentifier(UITestIdentifiers.keyStylePicker(key.keyCode))
        Picker("Tap or hold for \(key.fullName)", selection: activation(for: key, bindings: bindings)) {
          ForEach(TriggerActivation.allCases, id: \.self) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: Self.activationWidth, alignment: .trailing)
        .disabled(action == .off)
        .accessibilityIdentifier(UITestIdentifiers.keyActivationPicker(key.keyCode))
      }
    }
  }

  /// One key's action pop-up.
  private func choice(
    for key: TriggerKey, bindings: TriggerKeyBindings, profiles: [StyleProfile]
  ) -> Binding<TriggerKeyChoice> {
    Binding(
      get: { bindings.choice(for: key, profiles: profiles) },
      set: { newValue in
        // Refused only for the only dictating key, whose other choices the
        // pop-up disables.
        guard TriggerKeyStyleStore().setChoice(newValue, for: key) else { return }
        coordinator.dictationBindingChanged()
      })
  }

  /// One key's tap/hold pop-up.
  private func activation(for key: TriggerKey, bindings: TriggerKeyBindings) -> Binding<TriggerActivation> {
    Binding(
      get: { bindings.activation(for: key) },
      set: { newValue in
        TriggerKeyActivationStore().setActivation(newValue, for: key)
        coordinator.dictationBindingChanged()
      })
  }
}
