import BlurtEngine
import SwiftUI

/// "Auto-record meetings", in Settings › General: a switch, off until the user
/// turns it on. On, a recording starts when a meeting app takes the
/// microphone, or a browser has both held it and played audio for half a
/// minute, and stops soon after it lets go (`MeetingAutoRecord`). The stop half needs no switch: a recording started
/// by hand during a meeting ends with it either way.
struct MeetingAutoRecordSection: View {
  var model: TranscriptsModel
  @AppStorage(MeetingAutoRecordStore.defaultsKey) private var isOn = false

  var body: some View {
    Section {
      Toggle(isOn: $isOn) {
        SettingLabel(
          title: "Auto-record meetings", systemImage: "video",
          subtitle: "Records your mic and Mac audio.")
      }
      .accessibilityIdentifier(UITestIdentifiers.autoRecordToggle)
      .onChange(of: isOn) { _, isOn in model.setAutoRecordMeetings(isOn) }
    } header: {
      Text("Meetings")
    } footer: {
      // The when, below the row as the Microphone section's fallback note is,
      // so the subtitle stays one line.
      // Says the browser half plainly: a tab can't be told apart from
      // outside, so any page with two-way audio that long counts (#345).
      Text(
        "Recording starts when a meeting app uses the microphone, or a browser uses it and plays sound "
          + "for 30 seconds. The menu bar shows it while it records.")
    }
  }
}
