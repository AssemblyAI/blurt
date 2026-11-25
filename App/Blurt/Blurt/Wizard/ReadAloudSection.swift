import BlurtEngine
import SwiftUI

/// How read-aloud sounds — voice, speed, and skipping jargon
/// (`ReadAloudStyleStore`) — for every key that reads aloud or answers. The
/// Read Aloud tab's one section. The
/// router reads the same defaults at each press, so a change applies to the
/// next one.
struct ReadAloudSection: View {
  var coordinator: AppCoordinator

  // Observed so the section follows the Keys tab: with no key reading aloud
  // or asking, these settings do nothing, so they're disabled.
  @ObservedKeyBindings private var bindings

  @AppStorage(ReadAloudStyleStore.speedDefaultsKey)
  private var speed = ReadAloudStyleStore.defaultSpeed
  @AppStorage(ReadAloudStyleStore.voiceDefaultsKey)
  private var voiceID = ReadAloudStyleStore.defaultVoiceID
  @AppStorage(ReadAloudStyleStore.skipsJargonDefaultsKey)
  private var skipsJargon = ReadAloudStyleStore.defaultSkipsJargon

  /// The picker reads the stored speed through the same snap the press does, so
  /// a `defaults write` value off the list shows as the speed that will play.
  /// Picking a speed plays the sample at it, as picking a voice does.
  private var speedSelection: Binding<Double> {
    Binding(
      get: { ReadAloudStyleStore.nearestChoice(to: speed) },
      set: { newValue in
        speed = newValue
        coordinator.readAloudStyleChanged()
      }
    )
  }

  /// Same idea for the voice: a stored id the catalog doesn't list shows as the
  /// default voice, which is what the press will speak with. Picking one plays
  /// a sample, as the cue-sound picker does.
  private var voiceSelection: Binding<String> {
    Binding(
      get: { ReadAloudStyleStore.knownVoiceID(voiceID) },
      set: { newValue in
        voiceID = newValue
        coordinator.readAloudStyleChanged()
      }
    )
  }

  var body: some View {
    let readsOrAsks = bindings.readsOrAsks
    Section {
      Group {
        voicePicker
        speedPicker
        skipsJargonToggle
      }
      .disabled(!readsOrAsks)
    }
  }

  private var voicePicker: some View {
    PickerSettingRow(
      title: "Voice",
      systemImage: "person.wave.2",
      accessibilityID: UITestIdentifiers.readAloudVoicePicker,
      subtitle: "Choose a voice to hear a preview.",
      selection: voiceSelection
    ) {
      ForEach(ReadAloudVoice.Group.allCases, id: \.self) { group in
        Section(group.rawValue) {
          ForEach(ReadAloudVoice.catalog.filter { $0.group == group }) { voice in
            Text(voice.label).tag(voice.id)
          }
        }
      }
    }
  }

  private var speedPicker: some View {
    PickerSettingRow(
      title: "Speed",
      systemImage: "hare",
      accessibilityID: UITestIdentifiers.readAloudSpeedPicker,
      subtitle: "How quickly text is read.",
      selection: speedSelection
    ) {
      ForEach(ReadAloudStyleStore.speedChoices, id: \.self) { choice in
        Text(ReadAloudStyleStore.speedLabel(choice)).tag(choice)
      }
    }
  }

  private var skipsJargonToggle: some View {
    Toggle(isOn: $skipsJargon) {
      SettingLabel(
        title: "Skip technical text",
        systemImage: "text.badge.minus",
        subtitle: "Omits code, links, and long numbers."
      )
    }
    .accessibilityIdentifier(UITestIdentifiers.readAloudSkipsJargonToggle)
  }
}
