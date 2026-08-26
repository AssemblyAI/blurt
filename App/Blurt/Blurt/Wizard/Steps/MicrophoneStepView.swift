import BlurtEngine
import SwiftUI

/// The microphone section of the settings screen: a menu picker that either
/// follows the system's default input (the default) or pins dictation to one
/// specific input device, persisted as the device's UID via `MicDeviceStore`.
/// `MicCapture` re-reads the selection at every press, so a change applies to
/// the next dictation with nothing to push — and a pinned device that isn't
/// connected gracefully falls back to the system default
/// (`MicDeviceSelection.effective`), so no choice here can break dictation.
struct MicrophoneStepView: View {
  // Empty means "no device pinned" — the unset default belongs to
  // `MicDeviceSelection.fromPersisted`, which reads it as "same as system". See
  // `HotkeyStepView` for why the view must not restate it.
  @AppStorage(MicDeviceStore.defaultsKey) private var micDeviceUID = ""

  /// The input devices present when the pane appeared, re-read each time it
  /// does. A snapshot rather than a live listener: the picker's menu is built
  /// when it opens, and a device plugged in mid-session shows up on the next
  /// visit — the capture path resolves the UID fresh at every press regardless.
  ///
  @State private var devices: [AudioInputDevice] = []
  /// Whether `devices` has been read yet, as distinct from "read, and empty".
  /// Without the distinction `missingPin` took the empty initial value as "the
  /// pinned device is gone", so the picker showed "Disconnected microphone" for
  /// the 150–500 ms of a cold read — on a mic plugged in the whole time. A flag
  /// rather than an optional array because SwiftLint's
  /// `discouraged_optional_collection` (opted into repo-wide) forbids the latter.
  @State private var devicesLoaded = false
  /// The current default input's name, for the "Same as system (…)" label; nil
  /// (no device, or the read failed) drops the parenthetical.
  @State private var systemDefaultName: String?

  /// The selection as the engine's own type, not the raw slot. Binding the
  /// `String` meant spelling ""-means-system a second time (in a `.tag("")`),
  /// which is exactly what `MicDeviceSelection` exists to own — the same shape
  /// `SoundStepView` and `HotkeyStepView` already use for their pickers.
  private var selection: Binding<MicDeviceSelection> {
    Binding(
      get: { MicDeviceSelection.fromPersisted(micDeviceUID) },
      // Write through the store (see `HotkeyStepView` for why): the store owns
      // the encoding, `@AppStorage` observes the key to re-render.
      set: { MicDeviceStore().selection = $0 })
  }

  /// The stored pin when no connected device carries it — kept selectable so
  /// the picker can render the persisted choice instead of a blank control, and
  /// the user sees why dictation is currently using the system default.
  private var missingPin: MicDeviceSelection? {
    guard devicesLoaded, !micDeviceUID.isEmpty,
      !devices.contains(where: { $0.uid == micDeviceUID })
    else { return nil }
    return .pinned(uid: micDeviceUID)
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
        Text(systemDefaultLabel).tag(MicDeviceSelection.systemDefault)
        ForEach(devices) { device in
          Text(device.name).tag(MicDeviceSelection.pinned(uid: device.uid))
        }
        if let missingPin {
          Text("Disconnected microphone").tag(missingPin)
        }
      }
    } header: {
      Text("Microphone")
    } footer: {
      Text("Dictation records from this microphone. While it isn't connected, the system default is used.")
    }
    // Off the main actor, and `.task` rather than `.onAppear` to have somewhere
    // to await: enumerating devices is the first thing to touch AVFoundation's
    // capture stack in a process that hasn't dictated yet, measured at 150–500 ms
    // cold (~0.02 ms once warm). On a first-run install — where `AppCoordinator`
    // skips its launch warm-up because microphone access hasn't been granted —
    // that ran inline while this window was being laid out.
    .task {
      let snapshot = await Task.detached {
        (devices: AudioInputDevices.all(), defaultName: AudioInputDevices.systemDefaultInputName())
      }.value
      devices = snapshot.devices
      systemDefaultName = snapshot.defaultName
      devicesLoaded = true
    }
  }
}
