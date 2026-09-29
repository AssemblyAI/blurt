import Testing

@testable import BlurtiOS

@Suite("Brand type")
struct BlurtTypeTests {
  @Test("every face the tokens name is registered in this bundle")
  func registered() {
    #expect(BlurtType.missing().isEmpty, "unregistered: \(BlurtType.missing())")
    #expect(BlurtType.names.count == 6)
  }
}
