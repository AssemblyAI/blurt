import ApplicationServices
import Testing

@testable import BlurtEngine

/// The checked CFTypeRef downcasts behind the Accessibility reads
/// (`FocusCapture.axElement` / `.axRange`). Attribute values arrive from
/// *other apps'* AX implementations, so a wrong CF type must decode to `nil`,
/// never flow onward mistyped. Pure type checks — no Accessibility trust, no
/// focused element, and no cross-process IPC needed.
@Suite("FocusCapture checked AX downcasts")
struct AXDowncastTests {
  @Test("axElement passes a real AXUIElement through")
  func elementAccepted() {
    // The system-wide element is just a local ref — creating it needs no trust.
    #expect(FocusCapture.axElement(AXUIElementCreateSystemWide()) != nil)
  }

  @Test("axElement rejects a non-element CF value")
  func elementWrongTypeRejected() {
    #expect(FocusCapture.axElement("not an element" as CFString) == nil)
  }

  @Test("axRange decodes an AXValue-wrapped CFRange")
  func rangeDecoded() throws {
    var range = CFRange(location: 4, length: 2)
    let wrapped = try #require(AXValueCreate(.cfRange, &range))
    let decoded = try #require(FocusCapture.axRange(wrapped))
    #expect(decoded.location == 4)
    #expect(decoded.length == 2)
  }

  @Test("axRange rejects a non-AXValue CF value")
  func rangeWrongTypeRejected() {
    #expect(FocusCapture.axRange("not a range" as CFString) == nil)
  }

  @Test("axRange rejects an AXValue holding a non-range payload")
  func rangeWrongPayloadRejected() throws {
    var point = CGPoint(x: 1, y: 2)
    let wrapped = try #require(AXValueCreate(.cgPoint, &point))
    #expect(FocusCapture.axRange(wrapped) == nil)
  }
}
