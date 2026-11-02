import BlurtEngine
import SwiftUI

/// "Auto-record meetings", in Settings › General: a switch, off until the user
/// turns it on. On, a recording starts when a meeting app or a browser call
/// takes the microphone, and stops soon after it lets go
/// (`MeetingAutoRecord`). The stop half needs no switch: a recording started
/// by hand during a meeting ends with it either way.
struct MeetingAutoRecordSection: View {
  var model: TranscriptsModel
  @AppStorage(MeetingAutoRecordStore.defaultsKey) private var isOn = false

  var body: some View {
    Section {
      Toggle(isOn: $isOn) {
        SettingLabel(
          title: "Auto-record meetings", systemImage: "video",
          subtitle: "Records your mic and Mac audio while a meeting app or browser call uses the microphone.")
      }
      .accessibilityIdentifier(UITestIdentifiers.autoRecordToggle)
      .onChange(of: isOn) { _, isOn in model.setAutoRecordMeetings(isOn) }
    }
  }
}
