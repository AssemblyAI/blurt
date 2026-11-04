import Foundation

/// A fresh, empty directory under the temporary folder, for a test that needs
/// a real log file — so the host's own `~/Library/Logs/Blurt` is never touched.
func makeTempLogDirectory() -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("BlurtLogTests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
