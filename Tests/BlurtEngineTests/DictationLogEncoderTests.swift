import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// The shared encoder both logs write through.
@Suite("DictationLog.makeEncoder")
struct DictationLogEncoderTests {
  @Test("sorts keys, so the on-disk JSONL is byte-stable")
  func sortsKeys() {
    // Asserted on the encoder rather than by comparing where key names happen to
    // land in a written line: a stable diff for post-hoc greps is a property of
    // this configuration, and both logs share it.
    #expect(DictationLog.makeEncoder().outputFormatting.contains(.sortedKeys))
  }
}
