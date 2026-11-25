#if os(macOS)
  import Foundation
  import Synchronization

  /// Writes 16-bit mono PCM to a WAV file as it arrives: a header with the
  /// sizes left at zero, the samples appended, the sizes filled in by `finish`.
  /// Locked, because the speaker's task appends while a cancel may finish.
  final class WAVWriter: Sendable {
    private struct State {
      var handle: FileHandle?
      var bytes = 0
    }

    let url: URL
    private let state: Mutex<State>

    init(url: URL, sampleRate: Int) throws {
      self.url = url
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      // `.withoutOverwriting`: a clip never truncates another's audio.
      try Self.header(sampleRate: sampleRate, dataBytes: 0).write(to: url, options: .withoutOverwriting)
      state = Mutex(State(handle: try FileHandle(forWritingTo: url)))
      try state.withLock { _ = try $0.handle?.seekToEnd() }
    }

    /// The 44-byte canonical WAV header for 16-bit mono PCM.
    static func header(sampleRate: Int, dataBytes: Int) -> Data {
      var header = Data("RIFF".utf8)
      header += littleEndian(UInt32(36 + dataBytes))
      header += Data("WAVEfmt ".utf8)
      header += littleEndian(UInt32(16))  // fmt chunk size
      header += littleEndian(UInt16(1))  // PCM
      header += littleEndian(UInt16(1))  // mono
      header += littleEndian(UInt32(sampleRate))
      header += littleEndian(UInt32(sampleRate * 2))  // byte rate
      header += littleEndian(UInt16(2))  // block align
      header += littleEndian(UInt16(16))  // bits per sample
      header += Data("data".utf8)
      header += littleEndian(UInt32(dataBytes))
      return header
    }

    private static func littleEndian<Value: FixedWidthInteger>(_ value: Value) -> Data {
      unsafe withUnsafeBytes(of: value.littleEndian) { unsafe Data($0) }
    }

    func append(_ pcm: Data) {
      state.withLock { state in
        guard let handle = state.handle else {
          return
        }
        try? handle.write(contentsOf: pcm)
        state.bytes += pcm.count
      }
    }

    /// Fills in the sizes and closes the file; returns the audio's byte count.
    /// Idempotent.
    @discardableResult
    func finish() -> Int {
      state.withLock { state in
        guard let handle = state.handle else {
          return state.bytes
        }
        state.handle = nil
        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: Self.littleEndian(UInt32(36 + state.bytes)))
        try? handle.seek(toOffset: 40)
        try? handle.write(contentsOf: Self.littleEndian(UInt32(state.bytes)))
        try? handle.close()
        return state.bytes
      }
    }
  }
#endif
