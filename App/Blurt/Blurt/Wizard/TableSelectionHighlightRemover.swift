import AppKit
import SwiftUI

/// Turns off the enclosing table's own selection highlight — the one
/// SwiftUI's `List` draws on macOS and offers no modifier for — so the cards
/// draw their own. Found from a view inside the list, once it's in a window.
struct TableSelectionHighlightRemover: NSViewRepresentable {
  private final class Finder: NSView {
    private static func table(in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView {
        return table
      }
      for subview in view.subviews {
        if let table = table(in: subview) {
          return table
        }
      }
      return nil
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      DispatchQueue.main.async { [weak self] in self?.removeHighlight() }
    }

    func removeHighlight() {
      // The list's table is a sibling of this background, under a shared
      // ancestor: search down from each ancestor in turn.
      var ancestor = superview
      while let view = ancestor {
        if let table = Self.table(in: view) {
          table.selectionHighlightStyle = .none
          return
        }
        ancestor = view.superview
      }
    }
  }

  func makeNSView(context _: Context) -> NSView { Finder() }
  // Again on every update: the list builds its table after this view joins
  // the window, and may rebuild it.
  func updateNSView(_ nsView: NSView, context _: Context) {
    DispatchQueue.main.async { (nsView as? Finder)?.removeHighlight() }
  }
}
