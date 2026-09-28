import Foundation
import Testing

@testable import BlurtEngine

@Suite("Upload progress")
struct UploadProgressTests {
  @Test("counts delivered frames and timestamps the last one")
  func frames() {
    let progress = UploadProgress()
    #expect(progress.audioBytes == 0)
    #expect(progress.lastFrameAt == nil)
    progress.recordFrame(bytes: 4)
    let first = progress.lastFrameAt
    progress.recordFrame(bytes: 6)
    #expect(progress.audioBytes == 10)
    #expect(first != nil)
    #expect(progress.lastFrameAt != nil)
  }

  @Test("streamed upload cannot be replayed")
  func replay() async {
    let stream = await DictationUploadDelegate().urlSession(
      .shared,
      needNewBodyStreamForTask: URLSession.shared.dataTask(
        with: URL(string: "https://example.test")!))
    #expect(stream == nil)
  }
}
