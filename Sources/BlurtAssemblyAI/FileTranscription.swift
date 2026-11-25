/// A file's transcript both ways: speaker-labelled, which is what opens, and
/// plain, the same words without the labels.
public struct FileTranscription: Sendable, Equatable {
  /// One paragraph per turn, `Speaker A: …`, with more than one speaker;
  /// otherwise the plain text.
  public let text: String
  public let plainText: String
}
