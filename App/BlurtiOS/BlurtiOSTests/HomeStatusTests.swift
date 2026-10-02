import BlurtEngine
import Foundation
import Testing

@testable import BlurtiOSCore

@Suite("Home status")
struct HomeStatusTests {
  private func status(
    _ overlay: OverlayUIState, open: Bool = true, until: Date? = nil, key: Bool = true, mic: Bool = true,
    keyboard: Bool = true
  ) -> HomeStatus {
    HomeStatus(overlay: overlay, windowOpen: open, until: until, hasKey: key, micGranted: mic, keyboardSeen: keyboard)
  }

  @Test("the headline follows the phase, and says whether the mic is open at rest")
  func titles() {
    #expect(status(.idle).title == "Ready to dictate")
    #expect(status(.idle, open: false).title == "Not listening")
    #expect(status(.connecting).title == "Connecting…")
    #expect(status(.recording).title == "Listening…")
    #expect(status(.processing).title == "Transcribing…")
    #expect(status(.pasted).title == "Pasted")
    #expect(status(.noTarget).title == "Copied")
    #expect(status(.error(message: "No network.")).title == "No network.")
  }

  @Test("the line under it says how long the mic stays open")
  func subtitles() {
    #expect(status(.idle, open: false).subtitle.hasPrefix("Open the mic"))
    #expect(status(.idle, until: .distantFuture).subtitle.hasPrefix("Until you stop it"))
    #expect(status(.idle, until: Date()).subtitle.hasPrefix("Until "))
    #expect(!status(.idle, until: Date()).subtitle.hasPrefix("Until you"))
  }

  @Test("setup needs the key, the microphone and the keyboard; landed means pasted or copied")
  func setupAndLanded() {
    #expect(status(.idle).isSetUp)
    #expect(!status(.idle, key: false).isSetUp)
    #expect(!status(.idle, mic: false).isSetUp)
    #expect(!status(.idle, keyboard: false).isSetUp)
    #expect(status(.pasted).landed && status(.noTarget).landed)
    #expect(!status(.idle).landed && !status(.error(message: "x")).landed)
  }
}
