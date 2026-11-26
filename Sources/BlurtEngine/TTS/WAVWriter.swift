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
      /// Set by `seal`: the file takes no more audio, though it is still open.
      var sealed = false
    }

    /// The length of `header`: where the audio starts.
    private static let headerBytes = 44

    let url: URL
    private let sampleRate: Int
    private let state: Mutex<State>

    init(url: URL, sampleRate: Int) throws {
      self.url = url
      self.sampleRate = sampleRate
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
        guard let handle = state.handle, !state.sealed else {
          return
        }
        try? handle.write(contentsOf: pcm)
        state.bytes += pcm.count
      }
    }

    /// Ends the audio `seconds` before what has been appended — the part a
    /// stopped read had queued but not yet played — and takes no more. Whole
    /// samples only. Idempotent: only the first call trims.
    func seal(droppingLastSeconds seconds: Double) {
      state.withLock { state in
        guard let handle = state.handle, !state.sealed else {
          return
        }
        state.sealed = true
        let samples = seconds.isFinite && seconds > 0 ? Int(seconds * Double(sampleRate)) : 0
        let dropped = min(state.bytes, samples * 2)
        guard dropped > 0 else {
          return
        }
        state.bytes -= dropped
        try? handle.truncate(atOffset: UInt64(Self.headerBytes + state.bytes))
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
