import BlurtEngine
import Foundation

/// The device gate's trace: one JSON line per event — a window transition, a
/// press and its ack, the watchdog, a result, a hop — appended to
/// `Library/Logs/Blurt/trace.jsonl` beside the engine's own logs, behind
/// `-BlurtDeviceTrace YES`; debug builds only. `scripts/ios-device.sh pull`
/// takes the file off the phone. Never the dictated text, never the text
/// around the cursor: ids, states, reasons and times.
nonisolated enum DeviceTrace {
  static let fileName = "trace.jsonl"
  static let launchArgument = "BlurtDeviceTrace"
  #if DEBUG
    static let isEnabled = UserDefaults.standard.bool(forKey: launchArgument)
  #else
    static let isEnabled = false
  #endif
  private static let queue = DispatchQueue(label: HostIdentity.current.subsystem + ".trace")
  private static let encoder = JSONEncoder()

  /// Appends one line, off the caller's thread. Nothing when the flag is off.
  static func record(_ kind: String, _ fields: [String: String] = [:]) {
    guard isEnabled else { return }
    let line = line(kind, fields, at: Date())
    queue.async { append(line) }
  }

  /// One line: `{"t":…,"kind":…}` plus the fields, newline-terminated. Pure,
  /// so the shape is tested without a file.
  static func line(_ kind: String, _ fields: [String: String], at now: Date) -> Data {
    var entry = fields
    entry["t"] = now.ISO8601Format(.iso8601WithTimeZone(includingFractionalSeconds: true))
    entry["kind"] = kind
    var data = (try? encoder.encode(entry)) ?? Data()
    data.append(UInt8(ascii: "\n"))
    return data
  }

  private static func append(_ line: Data) {
    let url = HostIdentity.current.logURL(fileName)
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } catch {
      // A trace that can't be written is not worth a crash or a log storm.
    }
  }
}
