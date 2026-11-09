import BlurtEngine
import SwiftUI

/// The Sounds tab: one row per trigger key that does something, each with its
/// own start/stop cue voice (or None), so two keys never have to sound alike —
/// a read never sounds like a dictation starting unless the user wants it to.
/// A pane of its own after Keys rather than a column there: the key table
/// already fills the window's width. A key set to Off isn't listed, since it
/// has nothing to cue; its voice is kept for when it's turned back on.
///
/// A key with no voice of its own shows, and plays, its action's setting
/// (`TriggerKeySoundStore.soundPack(id:action:)`), so an untouched install
/// sounds as it did before keys had voices. Writes go through the store and
/// then the coordinator, which reloads that key's players and previews the
/// pick; `@AppStorage` only observes, as on `KeysSettingsTab`.
struct SoundsSettingsTab: View {
  let coordinator: AppCoordinator

  @ObservedKeyBindings private var bindings
  @AppStorage(TriggerKeySoundStore.defaultsKey) private var soundsRaw = ""

  var body: some View {
    let bindings = bindings
    let ids = TriggerKeySoundStore.soundIDs(decoding: soundsRaw)
    SettingsPane {
      Section {
        ForEach(TriggerKey.allCases.filter { bindings.action(for: $0) != .off }, id: \.self) { key in
          PickerSettingRow(
            title: key.spokenName, systemImage: KeysSettingsTab.symbol(for: key),
            accessibilityID: UITestIdentifiers.keySoundPicker(key.keyCode),
            subtitle: Self.actionName(bindings.action(for: key)),
            pickerLabel: "Sound for \(key.fullName)",
            selection: selection(for: key, id: ids[key], action: bindings.action(for: key))
          ) {
            packOptions
          }
        }
      }
    }
  }

  /// What the row's key does, as its subtitle — the same names the Keys tab's
  /// pop-ups use.
  private static func actionName(_ action: TriggerKeyAction) -> String {
    switch action {
    case .off: "Off"
    case .dictate: "Dictate"
    case .readAloud: KeyActionName.readAloud
    case .ask: KeyActionName.ask
    case .rewrite: KeyActionName.rewrite
    case .compose: KeyActionName.compose
    case .command: KeyActionName.command
    }
  }

  private func selection(for key: TriggerKey, id: String?, action: TriggerKeyAction) -> Binding<SoundPack> {
    Binding(
      get: { TriggerKeySoundStore.soundPack(id: id, action: action) },
      set: { newValue in
        TriggerKeySoundStore().setSoundID(newValue.id, for: key)
        coordinator.keySoundChanged(key)
      })
  }

  /// Every picker's options: None, then every voice by synth. One catalog's
  /// voices, so the lists can't drift apart.
  @ViewBuilder private var packOptions: some View {
    Text(SoundPack.none.label).tag(SoundPack.none)
    Divider()
    ForEach(SoundPackCatalog.blurt.groups, id: \.self) { group in
      Section(group) {
        ForEach(SoundPackCatalog.blurt.voices(in: group)) { pack in
          Text(pack.label).tag(pack)
        }
      }
    }
  }
}
