import Foundation

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
  package static func body(windowMinutes minutes: Int, locale: Locale = .autoupdatingCurrent) -> String {
    let leave = "Leave it here and the Blurt keyboard dictates in any app."
    guard minutes > 0 else {
      return "\(leave) It keeps listening until you stop it."
    }
    return "\(leave) It stops listening \(duration(minutes: minutes, locale: locale)) after your last word."
  }

  /// The corner tally, the old joke: the wordmark landing exactly in a corner.
  package static func tally(_ corners: Int) -> String { "Corners · \(corners)" }

  /// A listening window's length as words — "15 minutes", "1 hour" — the one
  /// source for this card and Settings' picker, pluralised by Foundation.
  package static func duration(minutes: Int, locale: Locale = .autoupdatingCurrent) -> String {
    let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .wide).locale(locale)
    return Duration.seconds(minutes * 60).formatted(style)
  }
}
