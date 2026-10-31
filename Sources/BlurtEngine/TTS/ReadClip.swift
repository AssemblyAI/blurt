#if os(macOS)
  import Foundation
  import Synchronization

  /// One finished read: what was read aloud, the audio as it played, and —
  /// for an answer — the spoken request it replied to. The app keeps it in its
  /// history (`SavedTranscript.Kind.readAloud`), findable and playable again.
  public struct ReadClip: Sendable, Equatable {
    /// The text read: the selection, or the answer.
    public let text: String
    /// The audio, a 16-bit mono WAV at the voice's sample rate. Holds what
    /// was synthesized, which for a read stopped early is where it stopped.
    public let audioURL: URL
    /// The request an answer replied to; nil for a plain read.
    public let request: String?
  }

  /// Where a speaker writes its clips, and who hears about each.
  public struct ReadClipSink: Sendable {
    let directory: URL
    let onClip: @Sendable (ReadClip) -> Void

    public init(directory: URL, onClip: @escaping @Sendable (ReadClip) -> Void) {
      self.directory = directory
      self.onClip = onClip
    }
  }

  /// A `PCMSink` that plays through `base` and copies every chunk into `writer`
  /// — how a read's audio is kept without touching the playback path.
  struct ClipRecordingSink: PCMSink {
    let base: any PCMSink
    let writer: WAVWriter

    func enqueue(_ pcm: Data) {
      writer.append(pcm)
      base.enqueue(pcm)
    }

    func drain() async { await base.drain() }
    func stop() { base.stop() }
    var currentLevel: Float { base.currentLevel }
    var bufferedSeconds: Double { base.bufferedSeconds }
  }

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

    func append(_ pcm: Data) {
      state.withLock { state in
        guard let handle = state.handle else { return }
        try? handle.write(contentsOf: pcm)
        state.bytes += pcm.count
      }
    }

    /// Fills in the sizes and closes the file; returns the audio's byte count.
    /// Idempotent.
    @discardableResult
    func finish() -> Int {
      state.withLock { state in
        guard let handle = state.handle else { return state.bytes }
        state.handle = nil
        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: Self.littleEndian(UInt32(36 + state.bytes)))
        try? handle.seek(toOffset: 40)
        try? handle.write(contentsOf: Self.littleEndian(UInt32(state.bytes)))
        try? handle.close()
        return state.bytes
      }
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
      withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
  }
#endif
