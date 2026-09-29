import CoreGraphics
import Foundation

/// The keyboard's touch rules, out of the views so they can be tested and
/// never drift between layouts (DESIGN.md › The two processes, and every
/// number): a key acts on release and only if the finger didn't travel; the
/// mic key waits a beat before it presses, so a swipe that starts on it never
/// starts a dictation it must then cancel; a horizontal swipe flips the
/// panel's carousel.
nonisolated enum KeyboardInteraction {
  /// The most a touch may travel and still be a tap on a key.
  static let tapTravel: CGFloat = 12
  /// A touch on the mic that travelled this far was a swipe, not a press.
  static let micTravel: CGFloat = 24
  /// A swipe flips the panel once it has gone this far sideways…
  static let swipeDistance: CGFloat = 48
  /// …and more sideways than up or down, by this factor.
  static let swipeRatio: CGFloat = 1.5
  /// How long a touch must stay before it counts as a press rather than the
  /// start of a swipe — well under a tap's own duration for a hold.
  static let micPressDelay: Duration = .milliseconds(90)

  enum FlipDirection: Equatable {
    /// The finger moved left: the incoming page arrives from the trailing edge.
    case towardsLeading
    case towardsTrailing
  }

  /// Which way the panel flips for this drag, or nil if the drag was not a swipe.
  static func flip(_ translation: CGSize) -> FlipDirection? {
    let dx = translation.width
    guard abs(dx) > swipeDistance, abs(dx) > abs(translation.height) * swipeRatio else { return nil }
    return dx < 0 ? .towardsLeading : .towardsTrailing
  }

  static func isTap(_ translation: CGSize) -> Bool {
    abs(translation.width) < tapTravel && abs(translation.height) < tapTravel
  }

  static func micTravelled(_ translation: CGSize) -> Bool {
    abs(translation.width) > micTravel || abs(translation.height) > micTravel
  }
}

/// The mic key's press, step by step: finger down arms a timer; the timer
/// firing sends the press; finger up decides. A tap quicker than the delay is
/// still a tap (press and release together); a swipe cancels the timer, or
/// undoes a press that already went out; nothing else happens. The view owns
/// the timer and the model calls; this owns the decisions.
nonisolated struct MicPressSequencer: Equatable {
  enum Outcome: Equatable {
    /// Release the key: send the press first if the timer never fired.
    case tap(needsDown: Bool)
    /// A swipe after the press went out: undo it.
    case cancelSentPress
    /// A swipe before the press went out: nothing to undo.
    case nothing
  }

  private(set) var pressed = false
  private(set) var timerArmed = false
  private(set) var pressSent = false

  /// The finger touched (or moved, again). True the first time: arm the timer.
  mutating func began() -> Bool {
    guard !pressed else { return false }
    pressed = true
    timerArmed = true
    return true
  }

  /// The finger moved. True when the timer must be cancelled: it travelled
  /// before the press went out.
  mutating func moved(travelled: Bool) -> Bool {
    guard travelled, timerArmed, !pressSent else { return false }
    timerArmed = false
    return true
  }

  /// The timer fired. True when the press goes out now.
  mutating func delayFired() -> Bool {
    guard pressed, timerArmed else { return false }
    timerArmed = false
    pressSent = true
    return true
  }

  /// The finger lifted.
  mutating func ended(travelled: Bool) -> Outcome {
    defer { self = MicPressSequencer() }
    if travelled { return pressSent ? .cancelSentPress : .nothing }
    return .tap(needsDown: !pressSent)
  }
}
