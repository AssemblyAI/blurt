import BlurtEngine
import Foundation

/// What the home screen says about the app's state, in words: the headline,
/// the line under it, whether setup is complete, whether the last dictation
/// just landed. Pure, so the wording is tested and the view only lays it out.
package nonisolated struct HomeStatus: Equatable {
  package let title: String
  package let subtitle: String
  /// A key, the microphone and the keyboard, all in place.
  package let isSetUp: Bool
  /// The words just went in (or to the clipboard): the hero's moment.
  package let landed: Bool

  package init(
    overlay: OverlayUIState, windowOpen: Bool, until: Date?, hasKey: Bool, micGranted: Bool, keyboardSeen: Bool
  ) {
    title = Self.title(overlay, windowOpen: windowOpen)
    if !windowOpen {
      subtitle = "Open the mic so the Blurt keyboard can dictate anywhere you type."
    } else if let until, until != .distantFuture {
      subtitle = "Until \(until.formatted(date: .omitted, time: .shortened)) · tap the mic on the Blurt keyboard."
    } else {
      subtitle = "Until you stop it · tap the mic on the Blurt keyboard."
    }
    isSetUp = hasKey && micGranted && keyboardSeen
    switch overlay {
    case .pasted, .noTarget: landed = true
    default: landed = false
    }
  }

  private static func title(_ overlay: OverlayUIState, windowOpen: Bool) -> String {
    switch overlay {
    case .connecting: "Connecting…"
    case .recording: "Listening…"
    case .processing: "Transcribing…"
    case .pasted: "Pasted"
    case .noTarget: "Copied"
    case .error(let message): message
    case .inputSilent: overlay.accessibilityLabel
    case .idle: windowOpen ? "Ready to dictate" : "Not listening"
    }
  }
}
