/// What a provider said about an API key: the outcome `APIKeySubmission`
/// decides on, apart from any one provider's validator. A provider package maps
/// its own check onto it (`BlurtAssemblyAI`'s `APIKeyValidator.blurt()`).
public enum KeyValidation: Sendable, Equatable {
  /// The provider accepted the key.
  case valid
  /// The provider rejected the key: bad, malformed, or unauthorized.
  case invalid
  /// The provider couldn't be reached, or answered with something that says
  /// nothing about the key. The key is not saved on this outcome.
  case unreachable
}
