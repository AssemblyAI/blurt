import Foundation

public protocol LocalAudioWriter: Sendable {
  var relativePath: String { get async }
  var fileURL: URL { get async }
  func append(_ pcm: Data) async throws
  func finish() async throws
  func cancelAndDelete() async
}

public actor WAVAudioWriter: LocalAudioWriter {
  public static let sampleRate = SyncSTTLimits.sampleRate
  public static let channelCount = SyncSTTLimits.channelCount
  public static let bitsPerSample = SyncSTTLimits.bitDepth

  public let relativePath: String
  public let fileURL: URL
  private var handle: FileHandle?
  private var audioByteCount: UInt32 = 0

  public init(jobID: UUID, baseDirectory: URL? = nil) throws {
    let root = try baseDirectory ?? Self.defaultDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    relativePath = "Audio/\(jobID.uuidString).wav"
    fileURL = root.appending(path: "\(jobID.uuidString).wav")
    FileManager.default.createFile(atPath: fileURL.path, contents: Self.header(audioBytes: 0))
    handle = try FileHandle(forWritingTo: fileURL)
    try handle?.seekToEnd()
  }

  public func append(_ pcm: Data) throws {
    guard let handle else { return }
    try handle.write(contentsOf: pcm)
    audioByteCount = audioByteCount.addingReportingOverflow(UInt32(pcm.count)).partialValue
  }

  public func finish() throws {
    guard let handle else { return }
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Self.header(audioBytes: audioByteCount))
    try handle.close()
    self.handle = nil
  }

  public func cancelAndDelete() {
    try? handle?.close()
    handle = nil
    try? FileManager.default.removeItem(at: fileURL)
  }

  public static func defaultDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    return support.appending(path: "VibeDictate/Audio", directoryHint: .isDirectory)
  }

  static func header(audioBytes: UInt32) -> Data {
    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    data.appendLittleEndian(36 &+ audioBytes)
    data.append(contentsOf: "WAVEfmt ".utf8)
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(channelCount))
    data.appendLittleEndian(UInt32(sampleRate))
    let bytesPerSample = UInt32(bitsPerSample / 8)
    data.appendLittleEndian(UInt32(sampleRate) * UInt32(channelCount) * bytesPerSample)
    data.appendLittleEndian(UInt16(channelCount * Int(bytesPerSample)))
    data.appendLittleEndian(UInt16(bitsPerSample))
    data.append(contentsOf: "data".utf8)
    data.appendLittleEndian(audioBytes)
    return data
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}

public struct PCMFrameFanout: Sendable {
  public let shortFrames: AsyncStream<Data>
  public let completion: Task<Void, any Error>
  private let shortFeed: ShortFrameFeed

  public init(source: AsyncStream<Data>, writer: any LocalAudioWriter) {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Data.self, bufferingPolicy: .unbounded)
    let shortFeed = ShortFrameFeed(continuation: continuation)
    self.shortFeed = shortFeed
    shortFrames = stream
    completion = Task {
      do {
        for await frame in source {
          try await writer.append(frame)
          shortFeed.yield(frame)
        }
        try await writer.finish()
        shortFeed.finish()
      } catch {
        shortFeed.finish()
        throw error
      }
    }
  }

  public func stopShortFeed() {
    shortFeed.finish()
  }
}

private final class ShortFrameFeed: Sendable {
  private struct State {
    var isFinished = false
  }

  private let continuation: AsyncStream<Data>.Continuation
  private let state = Mutex(State())

  init(continuation: AsyncStream<Data>.Continuation) {
    self.continuation = continuation
  }

  func yield(_ frame: Data) {
    let shouldYield = state.withLock { !$0.isFinished }
    if shouldYield { continuation.yield(frame) }
  }

  func finish() {
    let shouldFinish = state.withLock { state in
      guard !state.isFinished else { return false }
      state.isFinished = true
      return true
    }
    if shouldFinish { continuation.finish() }
  }
}
