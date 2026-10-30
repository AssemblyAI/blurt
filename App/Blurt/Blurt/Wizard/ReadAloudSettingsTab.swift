import BlurtEngine
import SwiftUI

/// The Read Aloud tab: its own pane, before Styles, rather than part of the
/// Keys tab — which keys read is a key's business, how a read sounds isn't.
struct ReadAloudSettingsTab: View {
  let coordinator: AppCoordinator

  var body: some View {
    SettingsPane {
      ReadAloudSection(coordinator: coordinator)
    }
  }
}

/// How read-aloud sounds — voice, speed, and skipping jargon
/// (`ReadAloudStyleStore`) — for every key that reads aloud or answers. The
/// Read Aloud tab's one section. The
/// router reads the same defaults at each press, so a change applies to the
/// next one.
struct ReadAloudSection: View {
  var coordinator: AppCoordinator

  // Observed so the section follows the Keys tab: with no key reading aloud
  // or asking, these settings do nothing, and asking adds its own note.
  @ObservedKeyBindings private var bindings

  @AppStorage(ReadAloudStyleStore.speedDefaultsKey) private var speed = ReadAloudStyleStore.defaultSpeed
  @AppStorage(ReadAloudStyleStore.voiceDefaultsKey) private var voiceID = ReadAloudStyleStore.defaultVoiceID
  @AppStorage(ReadAloudStyleStore.skipsJargonDefaultsKey)
  private var skipsJargon = ReadAloudStyleStore.defaultSkipsJargon

  /// The picker reads the stored speed through the same snap the press does, so
  /// a `defaults write` value off the list shows as the speed that will play.
  /// Picking a speed plays the sample at it, as picking a voice does.
  private var speedSelection: Binding<Double> {
    Binding(
      get: { ReadAloudStyleStore.nearestChoice(to: speed) },
      set: {
        speed = $0
        coordinator.readAloudStyleChanged()
      })
  }

  /// Same idea for the voice: a stored id the catalog doesn't list shows as the
  /// default voice, which is what the press will speak with. Picking one plays
  /// a sample, as the cue-sound picker does.
  private var voiceSelection: Binding<String> {
    Binding(
      get: { ReadAloudStyleStore.knownVoiceID(voiceID) },
      set: {
        voiceID = $0
        coordinator.readAloudStyleChanged()
      })
  }

  var body: some View {
    let bindings = bindings
    let readsOrAsks = bindings.readsOrAsks
    let asks = bindings.asks
    Section {
      Group {
        PickerSettingRow(
          title: "Voice", systemImage: "person.wave.2",
          accessibilityID: UITestIdentifiers.readAloudVoicePicker,
          subtitle: "Choose a voice to hear a preview.", selection: voiceSelection
        ) {
          ForEach(ReadAloudVoice.Group.allCases, id: \.self) { group in
            Section(group.rawValue) {
              ForEach(ReadAloudVoice.catalog.filter { $0.group == group }) { voice in
                Text(voice.label).tag(voice.id)
              }
            }
          }
        }
        PickerSettingRow(
          title: "Speed", systemImage: "hare",
          accessibilityID: UITestIdentifiers.readAloudSpeedPicker,
          subtitle: "How quickly text is read.", selection: speedSelection
        ) {
          ForEach(ReadAloudStyleStore.speedChoices, id: \.self) { choice in
            Text(ReadAloudStyleStore.speedLabel(choice)).tag(choice)
          }
        }
        Toggle(isOn: $skipsJargon) {
          SettingLabel(
            title: "Skip technical text", systemImage: "text.badge.minus",
            subtitle: "Omits code, links, and long numbers.")
        }
        .accessibilityIdentifier(UITestIdentifiers.readAloudSkipsJargonToggle)
      }
      .disabled(!readsOrAsks)
    } header: {
      Text("Playback")
    } footer: {
      // Each note is its own paragraph, and each says where the text goes: reading
      // aloud is on by default (left ⌥), so the first one always shows.
      if TriggerKey.allCases.contains(where: { bindings.action(for: $0) == .readAloud }) {
        Text("Select text, then use a key assigned to \(KeyActionName.readAloud).")
      } else if !readsOrAsks {
        Text("Assign a \(KeyActionName.readAloud) or \(KeyActionName.ask) key in Keys to enable playback.")
      }
      if asks {
        Text("Select text, then use an \(KeyActionName.ask) key and speak your request.")
        Text("Your selection and spoken request are sent to AssemblyAI’s LLM Gateway to generate an answer.")
      }
      if readsOrAsks {
        Text("Selected text is sent to AssemblyAI to read aloud.")
        if skipsJargon {
          Text("Skip technical text also sends your selection to AssemblyAI’s LLM Gateway before playback.")
        }
      }
    }
  }
}
