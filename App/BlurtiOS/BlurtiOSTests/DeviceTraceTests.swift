import BlurtEngine
import Foundation
import Testing

@testable import BlurtiOS

/// The device trace's line: one JSON object per event, the fields given and
/// nothing else, newline-terminated — and off unless the launch argument says.
@Suite("Device trace")
struct DeviceTraceTests {
  @Test("a line is one JSON object with the kind, the time and the fields, and ends the line")
  func line() throws {
    let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let line = DeviceTrace.line("press", ["id": "abc", "outcome": "started"], at: at)
    #expect(line.last == UInt8(ascii: "\n"))
    let object = try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: String]
    #expect(object?["kind"] == "press")
    #expect(object?["id"] == "abc")
    #expect(object?["outcome"] == "started")
    #expect(object?["t"]?.hasPrefix("2026-05-") == true)
    #expect(object?.count == 4)
    #expect(!DeviceTrace.isEnabled, "off unless -BlurtDeviceTrace YES")
    #expect(DeviceTrace.url.lastPathComponent == DeviceTrace.fileName)
  }
}
