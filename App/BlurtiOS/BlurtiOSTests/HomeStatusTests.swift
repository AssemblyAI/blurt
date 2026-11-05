import Foundation
import Testing

@testable import BlurtiOSCore

@Suite("Home status")
struct HomeStatusTests {
  private static let launch = UUID()

  private func record(_ window: ListeningState.Window, idle: ListeningState.Idle = .held, until: Date? = Date())
    -> ListeningState
  {
    ListeningState(launchID: Self.launch, sequence: 1, window: window, idle: idle, micLive: true, windowUntil: until)
  }

  private func status(
    _ state: ListeningState?, minutes: Int = 15, error: String? = nil, denied: Bool = false, key: Bool = true,
    mic: Bool = true, keyboard: Bool = true
  ) -> HomeStatus {
    HomeStatus(
      state: state, windowMinutes: minutes, error: error, micDenied: denied, hasKey: key, micGranted: mic,
      keyboardSeen: keyboard)
  }

  @Test("the session is on while the record says a window exists — opening, open or paused — and off otherwise")
  func session() {
    #expect(status(record(.open)).label == "Session on" && status(record(.open)).isOn)
    #expect(status(record(.opening)).isOn)
    #expect(status(record(.interrupted)).isOn)
    #expect(status(record(.closed)).label == "Session off" && !status(record(.closed)).isOn)
    #expect(!status(record(.closing)).isOn)
    #expect(!status(nil).isOn)
  }

  @Test("the line says what to do, how long an idle session lasts, and what the mic does between dictations")
  func message() {
    #expect(status(nil).message.hasPrefix("Start a session"))
    #expect(status(record(.closed)).message.hasPrefix("Start a session"))
    #expect(status(record(.opening)).message == "Starting the session…")
    #expect(status(record(.interrupted)).message.hasPrefix("The mic is paused"))
    #expect(status(record(.open)).message.contains("Ends after 15 idle minutes."))
    #expect(status(record(.open), minutes: 1).message.contains("Ends after 1 idle minute."))
    #expect(status(record(.open, until: nil), minutes: 0).message.contains("Stays on until you end it."))
    #expect(status(record(.open)).message.hasSuffix("The mic stays open while the session is on."))
    #expect(status(record(.open, idle: .pip)).message.hasSuffix("The mic opens only while you dictate."))
    #expect(status(record(.open), denied: true).message.hasPrefix("Blurt needs microphone access"))
  }

  @Test("a failed dictation's sentence is the card's error, held for the dwell DESIGN.md names")
  func error() {
    #expect(status(record(.open), error: "No network.").error == "No network.")
    #expect(status(record(.open)).error == nil)
    #expect(HomeStatus.errorDwell == 3)
  }

  @Test("setup needs the key, the microphone and the keyboard")
  func setup() {
    #expect(status(record(.open)).isSetUp)
    #expect(!status(record(.open), key: false).isSetUp)
    #expect(!status(record(.open), mic: false).isSetUp)
    #expect(!status(record(.open), keyboard: false).isSetUp)
  }
}
