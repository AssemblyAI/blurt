import BlurtEngine
import SwiftUI

/// The sound-cue section of the settings screen. A menu picker chooses the
/// record-start/stop voice (or None); the choice is persisted and the cue
/// players are reloaded immediately.
struct SoundStepView: View {
  var coordinator: AppCoordinator

  // Empty means "no pack persisted" — the unset default belongs to
  // `SoundPack.fromPersisted` (below), which names no known pack for `""` and so
  // resolves `defaultPack`. See `HotkeyStepView` for why the view must not restate
  // it.
  @AppStorage(SoundPackStore.defaultsKey) private var soundPackID = ""

  private var selection: Binding<SoundPack> {
    Binding(
      get: {
        SoundPack.fromPersisted(soundPackID)
      },
      set: { newValue in
        // Write through the store (see `HotkeyStepView` for why): the store owns the
        // encoding, `@AppStorage` observes the key to re-render.
        SoundPackStore().soundPack = newValue
        coordinator.soundPackChanged()
      })
  }

  var body: some View {
    Section {
      PickerSettingRow(
        title: "Cue sound", systemImage: "speaker.wave.2",
        accessibilityID: UITestIdentifiers.soundPicker, selection: selection
      ) {
        Text(SoundPack.none.label).tag(SoundPack.none)
        ForEach(SoundPack.groups, id: \.self) { group in
          Section(group) {
            ForEach(SoundPack.voices(in: group)) { pack in
              Text(pack.label).tag(pack)
            }
          }
        }
      }
    } header: {
      Text("Sound")
    } footer: {
      Text("Set to None to silence start and stop cues.")
    }
  }
}
