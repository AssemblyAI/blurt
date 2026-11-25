import Foundation
import Testing

@testable import BlurtEngine

@Suite("ElementSearch")
struct ElementSearchTests {
  @Test("the element search finds the pressable one by label, nearest the top first, within its limit")
  func elementSearch() {
    struct Node {
      let label: String
      let pressable: Bool
      var children: [Self] = []
    }
    let tree = Node(
      label: "window",
      pressable: false,
      children: [
        Node(label: "Send", pressable: false),
        Node(
          label: "toolbar",
          pressable: false,
          children: [Node(label: "Send Later", pressable: true), Node(label: "Send", pressable: true)]
        ),
        Node(label: "body", pressable: false, children: [Node(label: "Send", pressable: true, children: [])]),
      ]
    )
    func find(_ name: String, limit: Int = ElementSearch.maxElements) -> Node? {
      ElementSearch.best(
        named: name, from: tree, children: \.children, labels: { [$0.label] }, pressable: \.pressable, limit: limit
      )
    }
    #expect(find("send")?.label == "Send")
    #expect(find("send later")?.label == "Send Later")
    #expect(find("Archive") == nil)
    // Three nodes in, it hasn't reached the toolbar's buttons.
    #expect(find("send", limit: 3) == nil)
  }
}
