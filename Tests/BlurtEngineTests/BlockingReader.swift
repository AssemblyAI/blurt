import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// Carries the stream to the reading thread. `@unchecked Sendable` by
/// confinement: only that thread touches it once it is handed over.
final class BlockingReader: @unchecked Sendable {
  private let stream: InputStream

  init(_ stream: InputStream) { self.stream = stream }

  func read() -> Data {
    stream.open()
    defer { stream.close() }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 64)
    while true {
      let count = unsafe stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      received.append(contentsOf: buffer[0..<count])
    }
    return received
  }
}
