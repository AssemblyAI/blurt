import BlurtEngine
import SwiftUI

/// The sound-cue section of the settings screen. A menu picker chooses the
/// record-start/stop voice (or None); the choice is persisted and the cue
/// players are reloaded immediately.
struct SoundStepView: View {
  var coordinator: AppCoordinator

  // Empty means "no pack persisted" — the unset default belongs to
  // `SoundPackCatalog.fromPersisted` (below), which names no known voice for `""`
  // and so resolves the catalog's default. See `HotkeyStepView` for why the view
  // must not restate it.
  @AppStorage(SoundPackStore.defaultsKey) private var soundPackID = ""

  private var selection: Binding<SoundPack> {
    Binding(
      get: {
        SoundPackCatalog.blurt.fromPersisted(soundPackID)
      },
      set: { newValue in
        // Write through the store (see `HotkeyStepView` for why): the store owns the
        // encoding, `@AppStorage` observes the key to re-render.
        SoundPackStore(catalog: .blurt).soundPack = newValue
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
        ForEach(SoundPackCatalog.blurt.groups, id: \.self) { group in
          Section(group) {
            ForEach(SoundPackCatalog.blurt.voices(in: group)) { pack in
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

/// The microphone section of the settings screen: a menu picker that either
/// follows the system's default input (the default) or pins dictation to one
/// specific input device, persisted as the device's UID via `MicDeviceStore`.
/// `MicCapture` re-reads the selection at every press, so a change applies to
/// the next dictation with nothing to push — and a pinned device that isn't
/// connected gracefully falls back to the system default
/// (`MicDeviceSelection.effective`), so no choice here can break dictation.
///
/// In this file beside `SoundStepView` — the other audio section, whose picker
/// shape this mirrors — rather than its own, so the app target's file list (and
/// the generated project) is unchanged.
struct MicrophoneStepView: View {
  // Empty means "no device pinned" — the unset default belongs to
  // `MicDeviceSelection.fromPersisted` (below), which reads it as "same as
  // system". See `HotkeyStepView` for why the view must not restate it.
  @AppStorage(MicDeviceStore.defaultsKey) private var micDeviceUID = ""

  /// The input devices present when the pane appeared, re-read each time it
  /// does. A snapshot rather than a live listener: the picker's menu is built
  /// when it opens, and a device plugged in mid-session shows up on the next
  /// visit — the capture path resolves the UID fresh at every press regardless.
  @State private var devices: [AudioInputDevice] = []
  /// The current default input's name, for the "Same as system (…)" label; nil
  /// (no device, or the read failed) drops the parenthetical.
  @State private var systemDefaultName: String?

  private var selection: Binding<String> {
    Binding(
      get: { micDeviceUID },
      set: { newValue in
        // Write through the store (see `HotkeyStepView` for why): the store owns
        // the encoding, `@AppStorage` observes the key to re-render.
        MicDeviceStore().selection = MicDeviceSelection.fromPersisted(newValue)
      })
  }

  /// The stored pin when no connected device carries it — kept selectable so
  /// the picker can render the persisted choice instead of a blank control, and
  /// the user sees why dictation is currently using the system default.
  private var missingPinnedUID: String? {
    guard !micDeviceUID.isEmpty, !devices.contains(where: { $0.uid == micDeviceUID }) else {
      return nil
    }
    return micDeviceUID
  }

  private var systemDefaultLabel: String {
    systemDefaultName.map { "Same as system (\($0))" } ?? "Same as system"
  }

  var body: some View {
    Section {
      PickerSettingRow(
        title: "Input device", systemImage: "mic",
        accessibilityID: UITestIdentifiers.micPicker, selection: selection
      ) {
        Text(systemDefaultLabel).tag("")
        ForEach(devices) { device in
          Text(device.name).tag(device.uid)
        }
        if let missingPinnedUID {
          Text("Disconnected microphone").tag(missingPinnedUID)
        }
      }
    } header: {
      Text("Microphone")
    } footer: {
      Text("Dictation records from this microphone. While it isn't connected, the system default is used.")
    }
    .onAppear {
      devices = AudioInputDevices.all()
      systemDefaultName = AudioInputDevices.systemDefaultInputName()
    }
  }
}
