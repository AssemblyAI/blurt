import CoreGraphics
import Testing

@testable import BlurtEngine

/// A hand-built element: the attributes `ScreenNode` asks for, set directly,
/// so a test builds the three-node tree a rule is about rather than replaying
/// a recorded app. A class, so a tree can hold itself and two compare by `===`.
final class TinyNode: ScreenNode {
  let role: String?
  let subrole: String? = nil
  let title: String?
  let nodeDescription: String?
  let placeholder: String?
  let frame: CGRect?
  let isPressable: Bool
  let rawValue: String?
  let children: [TinyNode]
  let titleElement: TinyNode?

  init(
    _ role: String?,
    title: String? = nil,
    description: String? = nil,
    value: String? = nil,
    placeholder: String? = nil,
    frame: CGRect? = nil,
    pressable: Bool = false,
    label: TinyNode? = nil,
    children: [TinyNode] = []
  ) {
    self.role = role
    self.title = title
    nodeDescription = description
    self.placeholder = placeholder
    self.frame = frame
    isPressable = pressable
    rawValue = value
    self.children = children
    titleElement = label
  }

  static func button(_ title: String) -> TinyNode { TinyNode("AXButton", title: title) }
  static func text(_ words: String) -> TinyNode { TinyNode("AXStaticText", value: words) }
}
