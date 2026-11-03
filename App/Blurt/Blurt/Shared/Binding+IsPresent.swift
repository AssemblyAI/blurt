import SwiftUI

extension Binding {
  /// `true` while the optional holds a value; set to `false` (a dismissed
  /// alert or dialog), it clears the value. The `isPresented:` binding for
  /// `.alert`/`.confirmationDialog(_:isPresented:presenting:)`, derived from the
  /// one piece of state rather than a separate flag that could disagree with it.
  func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
    Binding<Bool>(
      get: { wrappedValue != nil },
      set: { if !$0 { wrappedValue = nil } })
  }
}
