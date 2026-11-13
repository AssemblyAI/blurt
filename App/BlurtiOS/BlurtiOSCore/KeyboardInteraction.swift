/// The bar's touch rule, out of the views so it can be tested: the chip acts
/// on release and only if the finger didn't travel. The keys' own touches
/// are KeyboardKit's, as Apple's keyboard has them.
package nonisolated enum KeyboardInteraction {
  /// The most a touch may travel and still be a tap.
  package static let tapTravel: Double = 12

  package static func isTap(width: Double, height: Double) -> Bool {
    abs(width) < tapTravel && abs(height) < tapTravel
  }
}
