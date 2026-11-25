import Foundation

/// One child pipe, read to EOF on a background thread so the child never blocks
/// on a full buffer while the caller waits for it to exit.
///
/// `@unchecked Sendable`: `text` is written once on the reading thread and read
/// only after `finish()`'s wait on `done`, which orders the two.
nonisolated final class PipeDrain: @unchecked Sendable {
  let pipe = Pipe()
  private let done = DispatchSemaphore(value: 0)
  private var text = ""

  func start() {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      text = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      done.signal()
    }
  }

  /// Everything the child wrote, trimmed. Returns once the pipe hit EOF.
  func finish() -> String {
    done.wait()
    return text
  }
}
