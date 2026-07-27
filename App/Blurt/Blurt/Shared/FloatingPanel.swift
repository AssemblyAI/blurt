import AppKit

enum FloatingPanel {
  static func make(
    size: CGSize,
    collectionBehavior: NSWindow.CollectionBehavior,
    contentView: NSView
  ) -> NSPanel {
    let panel = NSPanel(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.collectionBehavior = collectionBehavior
    panel.hidesOnDeactivate = false
    panel.contentView = contentView
    return panel
  }
}
