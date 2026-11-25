import Foundation

/// The app's outbound links, in the Help menu (`BlurtCommands`). Failable
/// construction throughout, so a caller omits its link rather than
/// force-unwrapping.
enum BlurtLinks {
  /// The repo's GitHub issues.
  static let reportBug = URL(string: "https://github.com/AssemblyAI/blurt/issues")

  /// LinkedIn's share intent. It takes only a URL to share, so this one
  /// carries no message.
  static let shareOnLinkedIn: URL? = {
    var components = URLComponents(string: "https://www.linkedin.com/sharing/share-offsite/")
    components?.queryItems = [URLQueryItem(name: "url", value: "https://www.assemblyai.com/blurt")]
    return components?.url
  }()
}
