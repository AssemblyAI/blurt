import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// What the router reported, in order.
@MainActor
final class Events {
  var started = 0
  var ended = 0
  var levels: [Float] = []
  var failures = 0
  var resets = 0
}
