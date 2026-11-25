import Foundation

/// A fresh directory holding one small file for an async client to "upload".
/// The caller removes the directory (`url.deletingLastPathComponent()`).
func scratchAudioFile() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "AsyncUpload-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appending(path: "call.m4a")
  try Data("audio bytes".utf8).write(to: url)
  return url
}
