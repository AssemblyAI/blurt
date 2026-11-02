import AppKit
import SwiftUI

/// `NSSearchField` for SwiftUI: the system's own search control — magnifying
/// glass, clear button, Esc to clear — which a styled `TextField` only
/// imitates. Filters as the user types.
struct SearchField: NSViewRepresentable {
  @Binding var text: String
  let prompt: String
  /// Bumped to put the cursor in the field — Edit › Find (⌘F), through the
  /// window's `focusHistorySearch` focused value.
  var focusRequest = 0

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = prompt
    field.controlSize = .small
    // A small control's own font: the default stays regular-size, so the
    // placeholder clipped in a field sized for small text.
    field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
    field.sendsSearchStringImmediately = true
    field.delegate = context.coordinator
    field.setAccessibilityLabel("Search history")
    field.setAccessibilityIdentifier(UITestIdentifiers.recentSearchField)
    context.coordinator.focusRequest = focusRequest
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    if field.stringValue != text { field.stringValue = text }
    if focusRequest != context.coordinator.focusRequest {
      context.coordinator.focusRequest = focusRequest
      field.window?.makeFirstResponder(field)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    let text: Binding<String>
    /// The last focus request acted on.
    var focusRequest = 0
    init(text: Binding<String>) { self.text = text }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      text.wrappedValue = field.stringValue
    }
  }
}

extension FocusedValues {
  /// Puts the cursor in the focused window's history search: what Edit › Find
  /// (⌘F) calls. Nil — and the menu item disabled — in a window without one.
  @Entry var focusHistorySearch: (() -> Void)?
}
