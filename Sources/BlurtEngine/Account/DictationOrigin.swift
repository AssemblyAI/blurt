import Foundation
import Synchronization

/// The dictation host a signed-in key belongs to, or nil to use the default
/// (production). A key minted by a sandbox sign-in only works against that
/// sandbox's dictation host, and a pasted key is a production key, so the host
/// follows the sign-in rather than the build.
///
/// `AssemblyAIAccount` keeps it current as it signs in and out. The app hands
/// the transcriber a `baseURL` closure that reads it at every request and
/// warm-up, off the main actor, so it is a `Mutex` rather than observable
/// state.
public final class DictationOrigin: Sendable {
  private let url = Mutex<URL?>(nil)

  public init() {}

  /// The signed-in key's host, or nil while signed out or when the sign-in
  /// configures none.
  public var current: URL? { url.withLock { $0 } }

  func set(_ newValue: URL?) {
    url.withLock { $0 = newValue }
  }
}
