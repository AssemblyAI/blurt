import SwiftUI

/// Bridges a SwiftUI scene to its hosting `NSWindow` so we can apply AppKit-only
/// window configuration that SwiftUI doesn't surface (e.g. a transparent
/// titlebar). Drop it in a `.background(...)`; `configure` runs once the view is
/// installed in a window, and again if the hosting window changes.
struct WindowAccessor: NSViewRepresentable {
  /// Called with the hosting window on the main actor, once `view.window` is
  /// non-nil. Re-invoked if the view later moves to a different window.
  var configure: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    apply(to: nsView, coordinator: context.coordinator)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    weak var configuredWindow: NSWindow?
  }

  /// Apply `configure` as soon as the view has joined a window, and again only
  /// when that window changes. `view.window` is nil during `makeNSView` and can
  /// still be nil on early `updateNSView` passes during a cold launch (the
  /// scene's NSWindow isn't on screen yet), so retry on the next runloop tick
  /// until the view has a window. The `weak view` capture stops the retry loop
  /// if the view is torn down before it ever joins one.
  private func apply(to view: NSView, coordinator: Coordinator) {
    guard let window = view.window else {
      DispatchQueue.main.async { [weak view] in
        guard let view else { return }
        apply(to: view, coordinator: coordinator)
      }
      return
    }
    guard window !== coordinator.configuredWindow else { return }
    coordinator.configuredWindow = window
    configure(window)
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

  /// Hide the titlebar chrome while keeping the traffic-light controls and the
  /// ability to close/reopen the window (Blurt is a Dock app). The titlebar goes
  /// transparent and the title text is hidden, so the window background flows up
  /// behind the controls — the "welcome window" look. The window stays draggable
  /// from its body since there's no longer a visible bar to grab.
  func chromeLightWindow() -> some View {
    background(
      WindowAccessor { window in
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
      }
    )
  }
}
