// Pure meter math, kept out of `MicCapture.swift` so the coverage gate sees it:
// the capture actor itself needs a real audio device and is excluded from the
// gate (see `scripts/check.sh`), but this DSP is deterministic and exercised by
// `MicCaptureFormatTests`.
extension MicCapture {
  /// Lowest dBFS meter reading treated as audible; anything quieter (room
  /// ambient) maps to 0. Deliberately set above typical built-in-mic noise so
  /// the overlay's voice bars read as empty at rest and only move for speech.
  static let meterFloorDB: Float = -50

  /// Convert `AVAudioRecorder`'s dBFS meter power into the `0...1` the overlay
  /// expects, mapped linearly across `[meterFloorDB, 0]`. (A raw `pow(10, db/20)`
  /// amplitude leaves ambient noise well above zero, so the bars never rested
  /// at empty.)
  static func linearLevel(fromPowerDB db: Float) -> Float {
    guard db.isFinite, db > meterFloorDB else { return 0 }
    return min(1, (db - meterFloorDB) / -meterFloorDB)
  }
}
