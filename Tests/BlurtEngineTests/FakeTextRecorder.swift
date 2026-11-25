#if os(macOS)
  import AppKit
  import ApplicationServices
  import Testing

  @testable import BlurtEngine

  /// A live tree copied into `RecordedNode`s: bounded, and with every string
  /// swapped for fake text — the same fake for the same string, so labels
  /// that matched still match — apart from `keep`'s generic interface words.
  struct FakeTextRecorder {
    static let nodeLimit = 6_000

    private(set) var count = 0
    private var fakes: [String: String] = [:]

    mutating func fake(_ text: String?) -> String? {
      guard let text, !text.isEmpty else {
        return nil
      }
      if RecordedNode.keptWords.contains(text) {
        return text
      }
      if let known = fakes[text] {
        return known
      }
      let made = "Lorem \(fakes.count + 1)"
      fakes[text] = made
      return made
    }

    mutating func record(_ node: AXRead.Node, depth: Int) -> RecordedNode {
      count += 1
      let role = node.role
      // A value only where it's a name or a row's text — never a field's contents.
      let valueNamed = role.map(RecordedNode.valueRoles.contains) ?? false
      let children: [RecordedNode] =
        depth < 40 && count < Self.nodeLimit ? node.children.map { record($0, depth: depth + 1) } : []
      let label = node.titleElement.map { titled in
        RecordedNode(
          role: titled.role,
          subrole: nil,
          title: fake(titled.title),
          nodeDescription: fake(titled.nodeDescription),
          placeholder: nil,
          frame: nil,
          pressable: false,
          rawValue: nil,
          children: [],
          label: nil
        )
      }
      return RecordedNode(
        role: role,
        subrole: node.subrole,
        title: fake(node.title),
        nodeDescription: fake(node.nodeDescription),
        placeholder: fake(node.placeholder),
        frame: node.frame,
        pressable: node.isPressable,
        rawValue: valueNamed ? fake(node.rawValue) : nil,
        children: children,
        label: label
      )
    }
  }
#endif
