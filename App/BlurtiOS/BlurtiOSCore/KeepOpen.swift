/// Blurt is on: the app-switcher card. When the user swipes up to the switcher
/// with a listening session on, Blurt's card shows this screen in place of
/// whatever the app was on, so the card says the one thing the user has to
/// know there — keep Blurt in the background, and the keyboard dictates in any
/// app. Its words, pure, so the wording is tested and `KeepOpenView` only lays
/// it out; the screensaver over the words is `Bounce`.
package nonisolated enum KeepOpen {
  package static let eyebrow = "Blurt is on"
  package static let headline = "Keep Blurt in the background."

  /// The line under the headline: leave it here, and for how long the mic
  /// stays open after the last word (`SharedStore.windowMinutes`, 0 for
  /// until the user stops it), in the words Settings uses for the same choice.
  package static func body(windowMinutes minutes: Int) -> String {
    let leave = "Leave it here and the Blurt keyboard dictates in any app."
    guard minutes > 0 else {
      return "\(leave) It keeps listening until you stop it."
    }
    return "\(leave) It stops listening \(duration(minutes)) after your last word."
  }

  /// The corner tally, the old joke: the wordmark landing exactly in a corner.
  package static func tally(_ corners: Int) -> String { "Corners · \(corners)" }

  private static func duration(_ minutes: Int) -> String {
    if minutes.isMultiple(of: 60) {
      let hours = minutes / 60
      return hours == 1 ? "1 hour" : "\(hours) hours"
    }
    return minutes == 1 ? "1 minute" : "\(minutes) minutes"
  }
}
