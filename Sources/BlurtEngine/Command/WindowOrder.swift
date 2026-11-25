import CoreGraphics

/// Whether an app owns the window on top, from the window server's on-screen
/// list, apart from it so the rule is tested.
enum WindowOrder {
  struct Window: Equatable {
    let owner: Int
    let layer: Int
    /// Where it is on screen, in the global top-left coordinates
    /// Accessibility uses; `.null` when the click check isn't asking.
    var bounds: CGRect = .null
  }

  /// The owner of the normal-layer window on top at `point`, front to back
  /// as `isFrontmost` reads them: whose window a click there would land in.
  /// Music brought forward with VS Code's window still over the spot took
  /// a click meant for Music's search field (2026-11-04).
  static func owner(at point: CGPoint, in windows: [Window]) -> Int? {
    windows.first { $0.layer == 0 && $0.bounds.contains(point) }?.owner
  }

  /// `windows` front to back, as `CGWindowListCopyWindowInfo` lists them.
  /// Only the normal layer (0) counts: the menu bar, the Dock and floating
  /// panels — Blurt's pill among them — sit above it. An app with no normal
  /// window on screen (its last one closed) passes: there's nothing of its to
  /// wait for.
  static func isFrontmost(_ pid: Int, in windows: [Window]) -> Bool {
    let normal = windows.filter { $0.layer == 0 }
    guard normal.contains(where: { $0.owner == pid }) else {
      return true
    }
    return normal.first?.owner == pid
  }
}
