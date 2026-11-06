import BlurtEngine
import SwiftUI

/// The Keys tab: one row per action a trigger key can take — dictate (with
/// the main window's style, no custom style, or each profile), read the
/// selection aloud, ask about it, rewrite it, or control the Mac — each with a
/// pop-up choosing the key that does it, or None. Below them, the one tap/hold
/// mode every key is pressed under. Changes are persisted and pushed to the
/// event tap immediately. Each key's start/stop cue is the Sounds tab's
/// (`SoundsSettingsTab`), and how read-aloud's voice sounds the Read Aloud
/// tab's (`ReadAloudSettingsTab`).
///
/// Storage is still keycode → action (`TriggerKeyStyleStore`); these rows are
/// a view of it, so a key does one thing and an action belongs to one key.
/// Reads go through `TriggerKeyBindings` (one decode per render) and writes
/// through the stores, never the raw `@AppStorage` slots: the stores own how a
/// choice and a mode are encoded, and the rules — choosing a key moves it off
/// its old action, and some key always dictates — live in
/// `TriggerKeyStyleStore.assign(_:to:)`, where they are tested. Assigning a
/// raw slot directly would leave the store's write with no production caller,
/// so an encoding change would keep `swift test` green while this view kept
/// writing the old form.
struct KeysSettingsTab: View {
  let coordinator: AppCoordinator

  @ObservedKeyBindings private var bindings
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  /// Each key's glyph: its row icon on the Sounds tab.
  static func symbol(for key: TriggerKey) -> String {
    switch key {
    case .rightCommand, .leftCommand: "command"
    case .rightOption, .leftOption: "option"
    case .leftControl: "control"
    case .function: "globe"
    }
  }

  /// One action row: what it does, and whether it rides the enhanced rewrite
  /// (a custom style, which is disabled with it off). Its icon is its
  /// action's, as on the main window.
  private struct ActionRow: Identifiable {
    let choice: TriggerKeyChoice
    let title: String
    var isStyled = false
    var id: String { title }
  }

  private func rows(profiles: [StyleProfile]) -> [ActionRow] {
    [
      ActionRow(choice: .dictate, title: "Dictate"),
      ActionRow(
        choice: .dictate(style: StyleProfileStore.defaultStyleID), title: "Dictate: No custom style",
        isStyled: true),
    ]
      + profiles.map {
        ActionRow(choice: .dictate(style: $0.id.uuidString), title: "Dictate: \($0.name)", isStyled: true)
      }
      + [
        ActionRow(choice: .readAloud, title: KeyActionName.readAloud),
        ActionRow(choice: .ask, title: KeyActionName.ask),
        ActionRow(choice: .rewrite, title: KeyActionName.rewrite),
        ActionRow(choice: .command, title: KeyActionName.command),
      ]
  }

  var body: some View {
    let bindings = bindings
    let profiles = StyleProfileStore().profiles(decoding: profilesRaw)
    SettingsPane {
      Section {
        ForEach(rows(profiles: profiles)) { row in
          keyRow(row, bindings: bindings, profiles: profiles)
        }
      }
      Section {
        PickerSettingRow(
          title: "Activation", systemImage: "hand.tap",
          accessibilityID: UITestIdentifiers.activationPicker,
          subtitle: bindings.activation.hint(for: .dictate), selection: activation
        ) {
          ForEach(TriggerActivation.allCases, id: \.self) { mode in
            Text(mode.label).tag(mode)
          }
        }
      }
    }
  }

  private func keyRow(_ row: ActionRow, bindings: TriggerKeyBindings, profiles: [StyleProfile]) -> some View {
    let holder = TriggerKey.allCases.first { bindings.choice(for: $0, profiles: profiles) == row.choice }
    // The only dictating key can't be left without dictation, so its row
    // offers no None — left out rather than disabled, since a menu pop-up
    // doesn't reliably disable single items.
    let canClear = holder.map { !bindings.isOnlyDictatingKey($0) } ?? true
    return PickerSettingRow(
      title: row.title, systemImage: row.choice.action.systemImage,
      accessibilityID: UITestIdentifiers.actionKeyPicker(row.title),
      pickerLabel: "Key for \(row.title)", selection: key(for: row.choice, holder: holder)
    ) {
      if canClear {
        Text("None").tag(TriggerKey?.none)
        Divider()
      }
      ForEach(TriggerKey.allCases, id: \.self) { key in
        Text(key.spokenName).tag(TriggerKey?.some(key))
      }
    }
    .disabled(row.isStyled && !enhancedTranscripts)
  }

  /// One action's key pop-up.
  private func key(for choice: TriggerKeyChoice, holder: TriggerKey?) -> Binding<TriggerKey?> {
    Binding(
      get: { holder },
      set: { newValue in
        // Refused only when it would leave no key dictating, which the
        // pop-ups already keep out of reach.
        guard TriggerKeyStyleStore().assign(newValue, to: choice) else { return }
        coordinator.dictationBindingChanged()
      })
  }

  /// The tap/hold pop-up every key shares.
  private var activation: Binding<TriggerActivation> {
    Binding(
      get: { bindings.activation },
      set: { newValue in
        TriggerActivationStore().setActivation(newValue)
        coordinator.dictationBindingChanged()
      })
  }
}
