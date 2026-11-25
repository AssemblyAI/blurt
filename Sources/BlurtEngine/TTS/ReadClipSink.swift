#if os(macOS)
  public import Foundation

  /// Where a speaker writes its clips, and who hears about each.
  public struct ReadClipSink: Sendable {
    let directory: URL
    let onClip: @Sendable (ReadClip) -> Void

    @preconcurrency
    public init(directory: URL, onClip: @escaping @Sendable (ReadClip) -> Void) {
      self.directory = directory
      self.onClip = onClip
    }
  }
#endif
