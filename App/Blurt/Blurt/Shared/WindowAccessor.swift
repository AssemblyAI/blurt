import SwiftUI

/// Bridges a SwiftUI scene to its hosting `NSWindow` so we can apply AppKit-only
/// window configuration that SwiftUI doesn't surface (e.g. a stable
/// `NSWindow.identifier`). Drop it in a `.background(...)`; `configure` runs once
/// the view is installed in a window, and again if the hosting window changes.
struct WindowAccessor: NSViewRepresentable {
  /// Called with the hosting window on the main actor, once the view has joined
  /// one. Re-invoked if the view later moves to a different window.
  var configure: (NSWindow) -> Void

  func makeNSView(context: Context) -> WindowReportingView {
    WindowReportingView(frame: .zero)
  }

  func updateNSView(_ nsView: WindowReportingView, context: Context) {
    // Refreshed on every update so the view calls the current closure.
    nsView.onWindow = configure
  }

  /// An empty view that reports its window the moment AppKit attaches it
  /// (`viewDidMoveToWindow`), rather than polling for one: `window` is nil in
  /// `makeNSView`, and can still be on early update passes during a cold launch,
  /// before the scene's window is on screen.
  final class WindowReportingView: NSView {
    var onWindow: ((NSWindow) -> Void)? {
      didSet { report() }
    }
    private weak var reported: NSWindow?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      report()
    }

    /// Once per window: a new window is configured, the same one isn't again.
    private func report() {
      guard let window, window !== reported, let onWindow else { return }
      reported = window
      onWindow(window)
    }
  }
}

extension View {
  /// Stamps the hosting `NSWindow` with a stable identifier so AppKit code can
  /// find that specific window later (e.g. to deminiaturize and raise it). SwiftUI
  /// doesn't guarantee a usable `NSWindow.identifier` for a `Window(id:)` scene, so
  /// we set our own rather than guessing at one.
  func windowIdentifier(_ id: String) -> some View {
    background(
      WindowAccessor { window in
        window.identifier = NSUserInterfaceItemIdentifier(id)
      }
    )
  }
}
