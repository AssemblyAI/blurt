import BlurtEngine
import SwiftUI

/// The sound-cue section of the settings screen. A menu picker chooses the
/// record-start/stop voice (or None); the choice is persisted and the cue
/// players are reloaded immediately.
struct SoundStepView: View {
  var coordinator: AppCoordinator

  @State private var selection: SoundPack = SoundPackStore().soundPack

  var body: some View {
    Section {
      LabeledContent {
        Picker("", selection: $selection) {
          Text(SoundPack.none.label).tag(SoundPack.none)
          ForEach(SoundPack.groups, id: \.self) { group in
            Section(group) {
              ForEach(SoundPack.voices(in: group)) { pack in
                Text(displayLabel(for: pack)).tag(pack)
              }
            }
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier("settings.sound.picker")
        .onChange(of: selection) { _, newValue in
          SoundPackStore().soundPack = newValue
          coordinator.soundPackChanged()
        }
      } label: {
        Label("Cue sound", systemImage: "speaker.wave.2")
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
