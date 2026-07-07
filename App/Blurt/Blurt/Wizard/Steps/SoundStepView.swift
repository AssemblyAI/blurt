import BlurtEngine
import SwiftUI

/// The sound-cue section of the settings screen. A menu picker chooses the
/// record-start/stop voice (or None); the choice is persisted and the cue
/// players are reloaded immediately.
struct SoundStepView: View {
  var coordinator: AppCoordinator

  @AppStorage(SoundPackStore.defaultsKey) private var soundPackID = SoundPack.defaultPack.id

  private var selection: Binding<SoundPack> {
    Binding(
      get: {
        SoundPack.find(id: soundPackID) ?? .defaultPack
      },
      set: { newValue in
        soundPackID = newValue.id
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
              Text(displayLabel(for: pack)).tag(pack)
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

  private func displayLabel(for pack: SoundPack) -> String {
    guard let synth = pack.synth else { return pack.label }
    return "\(pack.label) · \(synth)"
  }
}
