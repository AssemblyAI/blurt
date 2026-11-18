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
  package static func body(windowMinutes minutes: Int) -> String {
    let leave = "Leave it here and the Blurt keyboard dictates in any app."
    guard minutes > 0 else { return "\(leave) It keeps listening until you stop it." }
    return "\(leave) It stops listening \(duration(minutes)) after your last word."
  }

  /// The corner tally, the old joke: the wordmark landing exactly in a corner.
  package static func tally(_ corners: Int) -> String { "Corners · \(corners)" }

  private static func duration(_ minutes: Int) -> String {
    if minutes % 60 == 0 {
      let hours = minutes / 60
      return hours == 1 ? "1 hour" : "\(hours) hours"
    }
    return minutes == 1 ? "1 minute" : "\(minutes) minutes"
  }
}

/// The screensaver: an item drifting diagonally across a stage at a constant
/// speed and bouncing off its edges — the DVD player's logo. Each axis is a
/// triangle wave over the room the item leaves (`travel`), both at the same
/// speed, so the path is the 45° zigzag and every frame follows from the time
/// alone: the same frame at the same moment, in a test or a capture.
///
/// Every edge it touches counts (`wallHits`, the colour the view cycles); a
/// touch of one edge within `tolerance` of the other is a corner (`corners`,
/// the tally, and `lastCorner`, the flare). Exact corners are rare by nature,
/// so the start is chosen to land one `firstCorner` seconds in; after that
/// they come when the geometry allows.
package nonisolated struct Bounce: Equatable, Sendable {
  /// A corner the item landed in: when, and which.
  package struct Corner: Equatable, Sendable {
    package let at: TimeInterval
    package let trailing: Bool
    package let bottom: Bool
  }

  /// Where the item is, and what it has hit getting there.
  package struct Frame: Equatable, Sendable {
    /// The item's top-leading corner on the stage.
    package let origin: CGPoint
    package let wallHits: Int
    package let corners: Int
    package let lastCorner: Corner?
  }

  /// One axis: the distance the item has drifted along it, folded back and
  /// forth over the room it has.
  private struct Axis: Equatable, Sendable {
    let travel: CGFloat
    let start: CGFloat

    func distance(_ drift: CGFloat) -> CGFloat { start + drift }

    /// Walls touched by this distance; none on an axis with no room to move.
    func hits(_ distance: CGFloat) -> Int {
      travel > 0 ? Int((distance / travel).rounded(.down)) : 0
    }

    /// Out on the even legs, back on the odd ones.
    func position(_ distance: CGFloat) -> CGFloat {
      guard travel > 0 else { return 0 }
      let leg = hits(distance)
      let along = distance - CGFloat(leg) * travel
      return leg.isMultiple(of: 2) ? along : travel - along
    }
  }

  private let x: Axis
  private let y: Axis
  private let speed: CGFloat
  private let tolerance: CGFloat
  private let stage: CGSize
  private let item: CGSize

  /// An item of `item` size on a `stage`, drifting at `speed` points a second
  /// along each axis, started so that it lands in a corner `firstCorner`
  /// seconds in (sooner if the stage leaves no room on an axis).
  package init(stage: CGSize, item: CGSize, speed: CGFloat, firstCorner: TimeInterval, tolerance: CGFloat) {
    self.stage = stage
    self.item = item
    self.speed = speed
    self.tolerance = tolerance
    let drift = speed * CGFloat(firstCorner)
    // Back the start off from the moment both axes reach a wall together: the
    // first wall at or past the drift, minus the drift.
    func axis(_ travel: CGFloat) -> Axis {
      guard travel > 0 else { return Axis(travel: 0, start: 0) }
      let wall = max(1, (drift / travel).rounded(.up))
      return Axis(travel: travel, start: wall * travel - drift)
    }
    x = axis(max(0, stage.width - item.width))
    y = axis(max(0, stage.height - item.height))
  }

  /// The room the item has to move in: the stage less the item, per axis.
  package var travel: CGSize { CGSize(width: x.travel, height: y.travel) }

  /// Reduce Motion's frame, and the still one: dead centre, nothing hit.
  package var parked: Frame {
    Frame(
      origin: CGPoint(x: max(0, stage.width - item.width) / 2, y: max(0, stage.height - item.height) / 2),
      wallHits: 0, corners: 0, lastCorner: nil)
  }

  package func frame(at time: TimeInterval) -> Frame {
    let drift = speed * CGFloat(max(0, time))
    let distanceX = x.distance(drift)
    let distanceY = y.distance(drift)
    let (corners, lastCorner) = cornersHit(byDrift: drift)
    return Frame(
      origin: CGPoint(x: x.position(distanceX), y: y.position(distanceY)),
      wallHits: x.hits(distanceX) + y.hits(distanceY), corners: corners, lastCorner: lastCorner)
  }

  /// Every exact corner so far: at each wall the x axis has touched, is the y
  /// axis within `tolerance` of one of its own? Counted once both have
  /// touched, so the tally and the flare never run ahead of the picture.
  private func cornersHit(byDrift drift: CGFloat) -> (Int, Corner?) {
    guard x.travel > 0, y.travel > 0, speed > 0 else { return (0, nil) }
    var count = 0
    var last: Corner?
    let wallsX = x.hits(x.distance(drift))
    guard wallsX > 0 else { return (0, nil) }
    for wallX in 1...wallsX {
      // The drift at which x touches this wall, and where y is then.
      let atX = CGFloat(wallX) * x.travel - x.start
      let distanceY = y.distance(atX)
      let wallY = (distanceY / y.travel).rounded()
      guard wallY >= 1, abs(distanceY - wallY * y.travel) <= tolerance else { continue }
      let atY = wallY * y.travel - y.start
      let landed = max(atX, atY)
      guard landed <= drift else { continue }
      count += 1
      last = Corner(
        at: TimeInterval(landed / speed), trailing: !wallX.isMultiple(of: 2), bottom: !Int(wallY).isMultiple(of: 2))
    }
    return (count, last)
  }
}
