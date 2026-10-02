import CoreGraphics
import Foundation

/// The keyboard's touch rules, out of the views so they can be tested and
/// never drift between layouts (DESIGN.md › The two processes, and every
/// number): a key acts on release and only if the finger didn't travel; the
/// mic key waits a beat before it presses, so a swipe that starts on it never
/// starts a dictation it must then cancel; a horizontal swipe flips the
/// panel's carousel.
package nonisolated enum KeyboardInteraction {
  /// The most a touch may travel and still be a tap on a key.
  package static let tapTravel: CGFloat = 12
  /// A touch on the mic that travelled this far was a swipe, not a press.
  package static let micTravel: CGFloat = 24
  /// A swipe flips the panel once it has gone this far sideways…
  package static let swipeDistance: CGFloat = 48
  /// …and more sideways than up or down, by this factor.
  package static let swipeRatio: CGFloat = 1.5
  /// How long a touch must stay before it counts as a press rather than the
  /// start of a swipe — well under a tap's own duration for a hold.
  package static let micPressDelay: Duration = .milliseconds(90)

  package enum FlipDirection: Equatable {
    /// The finger moved left: the incoming page arrives from the trailing edge.
    case towardsLeading
    case towardsTrailing
  }

  /// Which way the panel flips for this drag, or nil if the drag was not a swipe.
  package static func flip(_ translation: CGSize) -> FlipDirection? {
    let dx = translation.width
    guard abs(dx) > swipeDistance, abs(dx) > abs(translation.height) * swipeRatio else { return nil }
    return dx < 0 ? .towardsLeading : .towardsTrailing
  }

  package static func isTap(_ translation: CGSize) -> Bool {
    abs(translation.width) < tapTravel && abs(translation.height) < tapTravel
  }

  /// How far past a key's edge a finger may end and still have tapped it.
  package static let tapSlop: CGFloat = 8

  /// A key's tap: the finger barely moved, or it ended on the key (within
  /// `tapSlop` of its edges) wherever it went in between — a thumb that rolls
  /// still types, as on the system keyboard, while a swipe that left the key
  /// (the panel's carousel) does not. `location` is in the key's own space.
  package static func isTap(_ translation: CGSize, endedAt location: CGPoint, in size: CGSize) -> Bool {
    if isTap(translation) { return true }
    guard size.width > 0, size.height > 0 else { return false }
    return CGRect(origin: .zero, size: size).insetBy(dx: -tapSlop, dy: -tapSlop).contains(location)
  }

  package static func micTravelled(_ translation: CGSize) -> Bool {
    abs(translation.width) > micTravel || abs(translation.height) > micTravel
  }
}

/// The mic key's press, step by step: finger down arms a timer; the timer
/// firing sends the press; finger up decides. A tap quicker than the delay is
/// still a tap (press and release together); a swipe cancels the timer, or
/// undoes a press that already went out; nothing else happens. The view owns
/// the timer and the model calls; this owns the decisions.
package nonisolated struct MicPressSequencer: Equatable {
  package enum Outcome: Equatable {
    /// Release the key: send the press first if the timer never fired.
    case tap(needsDown: Bool)
    /// A swipe after the press went out: undo it.
    case cancelSentPress
    /// A swipe before the press went out: nothing to undo.
    case nothing
  }

  package private(set) var pressed = false
  package private(set) var timerArmed = false
  package private(set) var pressSent = false

  package init() {}

  /// The finger touched (or moved, again). True the first time: arm the timer.
  package mutating func began() -> Bool {
    guard !pressed else { return false }
    pressed = true
    timerArmed = true
    return true
  }

  /// The finger moved. True when the timer must be cancelled: it travelled
  /// before the press went out.
  package mutating func moved(travelled: Bool) -> Bool {
    guard travelled, timerArmed, !pressSent else { return false }
    timerArmed = false
    return true
  }

  /// The timer fired. True when the press goes out now.
  package mutating func delayFired() -> Bool {
    guard pressed, timerArmed else { return false }
    timerArmed = false
    pressSent = true
    return true
  }

  /// The finger lifted.
  package mutating func ended(travelled: Bool) -> Outcome {
    defer { self = MicPressSequencer() }
    if travelled { return pressSent ? .cancelSentPress : .nothing }
    return .tap(needsDown: !pressSent)
  }
}
