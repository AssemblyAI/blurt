import AppKit

@MainActor
enum FloatingPanel {
  static func make(
    size: CGSize,
    collectionBehavior: NSWindow.CollectionBehavior,
    contentView: NSView
  ) -> NSPanel {
    let p = NSPanel(
      contentRect: .init(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = .floating
    p.collectionBehavior = collectionBehavior
    p.hidesOnDeactivate = false
    p.contentView = contentView
    return p
  }
}
