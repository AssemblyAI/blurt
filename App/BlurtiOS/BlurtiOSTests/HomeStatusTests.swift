import BlurtEngine
import Testing

@testable import BlurtiOSCore

@Suite("Home status")
struct HomeStatusTests {
  private func status(
    _ overlay: OverlayUIState = .idle, open: Bool = true, minutes: Int = 15, denied: Bool = false, key: Bool = true,
    mic: Bool = true, keyboard: Bool = true
  ) -> HomeStatus {
    HomeStatus(
      overlay: overlay, windowOpen: open, windowMinutes: minutes, micDenied: denied, hasKey: key, micGranted: mic,
      keyboardSeen: keyboard)
  }

  @Test("the session is on while the window is open, off when it isn't, whatever the dictation is doing")
  func session() {
    #expect(status().label == "Session on" && status().isOn)
    #expect(status(open: false).label == "Session off" && !status(open: false).isOn)
    #expect(status(.recording).label == "Session on")
  }

  @Test("the line says what to do, and how long an idle session lasts")
  func message() {
    #expect(status(open: false).message.hasPrefix("Start a session"))
    #expect(status().message.hasSuffix("Ends after 15 idle minutes."))
    #expect(status(minutes: 1).message.hasSuffix("Ends after 1 idle minute."))
    #expect(status(minutes: 0).message.hasSuffix("Stays on until you end it."))
    #expect(status(denied: true).message.hasPrefix("Blurt needs microphone access"))
  }

  @Test("a failed dictation says why; nothing else is an error")
  func error() {
    #expect(status(.error(message: "No network.")).error == "No network.")
    #expect(status(.pasted).error == nil && status(.recording).error == nil)
  }

  @Test("setup needs the key, the microphone and the keyboard")
  func setup() {
    #expect(status().isSetUp)
    #expect(!status(key: false).isSetUp)
    #expect(!status(mic: false).isSetUp)
    #expect(!status(keyboard: false).isSetUp)
  }
}
