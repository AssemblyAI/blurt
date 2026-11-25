import SwiftUI

/// The everyday setup a user changes: the AssemblyAI account, the microphone,
/// and whether meetings record themselves. The trigger keys and their cue
/// sounds are their own tabs (`KeysSettingsTab`, `SoundsSettingsTab`). Key terms live on Vocabulary,
/// beside the text shortcuts — both are "words Blurt should know".
struct GeneralSettingsTab: View {
  let coordinator: AppCoordinator

  var body: some View {
    SettingsPane {
      APIKeyStepView(apiKey: coordinator.apiKey, account: coordinator.account)
      MicrophoneStepView()
      MeetingAutoRecordSection(model: coordinator.transcripts)
    }
  }
}
