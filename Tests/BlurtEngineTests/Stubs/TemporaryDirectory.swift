import Foundation

/// A fresh, empty directory under the temporary folder, named `prefix-<UUID>`
/// so a folder a crashed run left behind says which suite made it, and given
/// `pathExtension` when the fixture is typed by it (an `.app` bundle).
private func makeTemporaryDirectory(named prefix: String, pathExtension: String?) throws -> URL {
  var name = "\(prefix)-\(UUID().uuidString)"
  if let pathExtension {
    name += ".\(pathExtension)"
  }
  let directory = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

/// Runs `body` with a fresh, empty directory under the temporary folder, and
/// removes the directory — and whatever `body` left in it — however `body` ends.
/// A directory `body` already removed is not an error.
@discardableResult
func withTemporaryDirectory<T>(
  named prefix: String = "BlurtEngineTests",
  pathExtension: String? = nil,
  _ body: (URL) throws -> T
) throws -> T {
  let directory = try makeTemporaryDirectory(named: prefix, pathExtension: pathExtension)
  defer { try? FileManager.default.removeItem(at: directory) }
  return try body(directory)
}

/// The async form of `withTemporaryDirectory`, for a body that awaits.
@discardableResult
func withTemporaryDirectory<T>(
  named prefix: String = "BlurtEngineTests",
  pathExtension: String? = nil,
  _ body: (URL) async throws -> T
) async throws -> T {
  let directory = try makeTemporaryDirectory(named: prefix, pathExtension: pathExtension)
  defer { try? FileManager.default.removeItem(at: directory) }
  return try await body(directory)
}

/// Runs `body` with the URL of a log file named `fileName` that doesn't exist
/// yet, in a fresh temporary directory removed when `body` returns — so a test
/// that needs a real log file never touches the host's own `~/Library/Logs/Blurt`.
func withTempLogFile(_ fileName: String, _ body: (URL) throws -> Void) throws {
  try withTemporaryDirectory(named: "BlurtLogTests") { directory in
    try body(directory.appending(path: fileName))
  }
}
