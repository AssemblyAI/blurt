#if os(macOS)
  import Foundation
  import Synchronization

  /// A `PCMSink` that plays through `base` and copies every chunk into `writer`
  /// — how a read's audio is kept without touching the playback path.
  ///
  /// Chunks are enqueued up to `SelectionSpeaker.bufferTarget` ahead of the
  /// listener, so a stopped read's file would otherwise hold audio nobody
  /// heard. `stop` trims what `base` still had queued and keeps out anything
  /// the stream yields after it: the clip ends where the listening did.
  final class ClipRecordingSink: PCMSink {
    let base: any PCMSink
    let writer: WAVWriter
    /// Held across a copy and its enqueue, and across `stop`'s measure and
    /// trim, so a chunk is either both written and queued or neither when
    /// the unplayed audio is measured.
    private let stopped = Mutex(false)
    var currentLevel: Float { base.currentLevel }
    var bufferedSeconds: Double { base.bufferedSeconds }
    var unplayedAudioSeconds: Double { base.unplayedAudioSeconds }

    init(base: any PCMSink, writer: WAVWriter) {
      self.base = base
      self.writer = writer
    }

    func enqueue(_ pcm: Data) {
      stopped.withLock { isStopped in
        if !isStopped { writer.append(pcm) }
        base.enqueue(pcm)
      }
    }

    func drain() async { await base.drain() }

    func stop() {
      stopped.withLock { isStopped in
        guard !isStopped else {
          return
        }
        isStopped = true
        writer.seal(droppingLastSeconds: base.unplayedAudioSeconds)
      }
      base.stop()
    }
  }
#endif
