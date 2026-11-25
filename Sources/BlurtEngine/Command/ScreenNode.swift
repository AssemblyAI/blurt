import CoreFoundation

/// What a screen read needs of one element of a window's tree: the
/// Accessibility node it reads live (`AXRead.Node`), or one recorded from a
/// real app and replayed in a test (`Tests/ScreenTrees`). Everything here is
/// asked only as the read needs it — a live node pays a round trip for some.
protocol ScreenNode {
  var role: String? { get }
  var subrole: String? { get }
  var title: String? { get }
  /// Its `AXDescription`: an icon button's spoken name.
  var nodeDescription: String? { get }
  var placeholder: String? { get }
  var frame: CGRect? { get }
  /// Whether it takes `AXPress`.
  var isPressable: Bool { get }
  /// Its `AXValue`, asked only where that's a name (`ScreenSnapshot.valueNamedRoles`)
  /// or a row's text inside it — never a text entry's contents.
  var rawValue: String? { get }
  var children: [Self] { get }
  /// The element its `AXTitleUIElement` points at: a web form control's `<label>`.
  var titleElement: Self? { get }
}
