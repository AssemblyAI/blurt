#if os(macOS)
  import Foundation

  /// A `PCMSink` that plays through `base` and copies every chunk into `writer`
  /// — how a read's audio is kept without touching the playback path.
  struct ClipRecordingSink: PCMSink {
    let base: any PCMSink
    let writer: WAVWriter
    var currentLevel: Float { base.currentLevel }
    var bufferedSeconds: Double { base.bufferedSeconds }

    func enqueue(_ pcm: Data) {
      writer.append(pcm)
      base.enqueue(pcm)
    }

    func drain() async { await base.drain() }
    func stop() { base.stop() }
  }
#endif
