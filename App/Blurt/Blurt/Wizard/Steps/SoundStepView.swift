import BlurtEngine
import SwiftUI

/// The sound-cue section of the settings screen. Three menu pickers choose the
/// start/stop voice (or None) for dictation, for read-aloud and for Control
/// Your Mac — each its own pair, so a read or a command never sounds like a
/// dictation starting. Each choice is persisted,
/// its players reloaded, and a preview played immediately.
struct SoundStepView: View {
  var coordinator: AppCoordinator

  // Empty means "no pack persisted" — the unset default belongs to
  // `SoundPackCatalog.fromPersisted` (below), which names no known voice for `""`
  // and so resolves the catalog's default. See `KeysSettingsTab` for why the view
  // must not restate it.
  @AppStorage(SoundPackStore.defaultsKey) private var soundPackID = ""
  @AppStorage(SoundPackStore.readAloudDefaultsKey) private var readAloudPackID = ""
  @AppStorage(SoundPackStore.commandDefaultsKey) private var commandPackID = ""

  private var selection: Binding<SoundPack> {
    Binding(
      get: {
        SoundPackCatalog.blurt.fromPersisted(soundPackID)
      },
      set: { newValue in
        // Write through the store (see `KeysSettingsTab` for why): the store owns the
        // encoding, `@AppStorage` observes the key to re-render.
        SoundPackStore.dictation.soundPack = newValue
        coordinator.soundPackChanged()
      })
  }

  /// Read-aloud's pack, the same way, through its own catalog default.
  private var readAloudSelection: Binding<SoundPack> {
    Binding(
      get: { SoundPackCatalog.blurtReadAloud.fromPersisted(readAloudPackID) },
      set: { newValue in
        SoundPackStore.readAloud.soundPack = newValue
        coordinator.readAloudSoundPackChanged()
      })
  }

  /// Control Your Mac's pack, the same way, through its own catalog default.
  private var commandSelection: Binding<SoundPack> {
    Binding(
      get: { SoundPackCatalog.blurtCommand.fromPersisted(commandPackID) },
      set: { newValue in
        SoundPackStore.command.soundPack = newValue
        coordinator.commandSoundPackChanged()
      })
  }

  /// Every picker's options: None, then every voice by synth. One catalog's
  /// voices, so the lists can't drift apart.
  @ViewBuilder private var packOptions: some View {
    Text(SoundPack.none.label).tag(SoundPack.none)
    ForEach(SoundPackCatalog.blurt.groups, id: \.self) { group in
      Section(group) {
        ForEach(SoundPackCatalog.blurt.voices(in: group)) { pack in
          Text(pack.label).tag(pack)
        }
      }
    }
  }

  var body: some View {
    Section {
      PickerSettingRow(
        title: "Dictation", systemImage: "speaker.wave.2",
        accessibilityID: UITestIdentifiers.soundPicker,
        subtitle: "Start and stop recording.", selection: selection
      ) {
        packOptions
      }
      PickerSettingRow(
        title: "Read aloud", systemImage: "speaker.wave.2.bubble",
        accessibilityID: UITestIdentifiers.readAloudSoundPicker,
        subtitle: "Start and stop playback.", selection: readAloudSelection
      ) {
        packOptions
      }
      PickerSettingRow(
        title: "Control Your Mac", systemImage: "command",
        accessibilityID: UITestIdentifiers.commandSoundPicker,
        subtitle: "Start and stop a spoken command.", selection: commandSelection
      ) {
        packOptions
      }
    } header: {
      Text("Sounds")
    } footer: {
      Text("Choose None to turn off start and stop sounds.")
    }
  }
}
