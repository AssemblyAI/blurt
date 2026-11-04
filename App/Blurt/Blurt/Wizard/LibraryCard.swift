import AppKit
import SwiftUI

/// Turns off the enclosing table's own selection highlight — the one
/// SwiftUI's `List` draws on macOS and offers no modifier for — so the cards
/// draw their own. Found from a view inside the list, once it's in a window.
struct TableSelectionHighlightRemover: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { Finder() }
  // Again on every update: the list builds its table after this view joins
  // the window, and may rebuild it.
  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { (nsView as? Finder)?.removeHighlight() }
  }

  private final class Finder: NSView {
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

    private static func table(in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView { return table }
      for subview in view.subviews {
        if let table = table(in: subview) { return table }
      }
      return nil
    }
  }
}

/// A Library card, drawn as a list row's background: white, rounded and
/// lifted, inset by the window's margin and half the gap between cards; when
/// selected, ringed in the accent, as Journal marks an entry.
struct LibraryCard: View {
  let isSelected: Bool

  /// The space between two cards.
  static let gap: CGFloat = 4
  /// The selection ring's width, outside the card.
  static let ring: CGFloat = 3

  var body: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(Color(nsColor: .textBackgroundColor))
      .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
      // Selected, as Journal marks an entry: a thick accent ring just
      // outside the card, its corners following the card's.
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 12 + Self.ring, style: .continuous)
            .fill(BlurtBrand.accent)
            .padding(-Self.ring)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, Self.gap)
  }
}
