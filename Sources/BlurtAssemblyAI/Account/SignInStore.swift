import BlurtEngine
import Foundation

/// Keychain storage for the `SignInSession`, as JSON in its own item next to the
/// API key. `read`/`write` are closures, the way `MemoizedKeyStore` takes its
/// storage, so tests hand over a double instead of the real item.
public struct SignInStore: Sendable {
  /// A read that keeps "nothing stored" apart from "couldn't read it" (a locked
  /// Keychain, an ACL prompt pending after a re-sign) — the distinction
  /// `KeychainStore.ReadResult` exists for. Treating the second as the first
  /// would show a signed-in Mac as signed out, and let Sign Out delete the key
  /// without ending the connection.
  public enum Load: Sendable, Equatable {
    case empty
    case session(SignInSession)
    case unavailable

    /// The stored session, or nil when there is none or it can't be read.
    public var session: SignInSession? {
      if case .session(let session) = self { session } else { nil }
    }
  }

  /// The Keychain account the session is stored under, beside the key's.
  /// `scripts/reset-lib.sh` deletes it by name; `ResetScriptContractTests` pins
  /// the two together.
  static let keychainAccount = "AssemblyAISignIn"

  /// The production item, in the host's Keychain service.
  public static let production: SignInStore = {
    let keychain = KeychainStore(service: HostIdentity.current.keychainService, account: keychainAccount)
    return Self(read: { keychain.read() }, write: { keychain.write($0) })
  }()

  private let read: @Sendable () -> KeychainStore.ReadResult
  private let write: @Sendable (String?) -> Bool

  public var load: Load {
    switch read() {
    case .absent:
      return .empty

    case .unavailable:
      return .unavailable

    case .value(let json):
      // An item that doesn't decode is as good as none: nothing in it can be
      // refreshed.
      guard let session = try? JSONDecoder.signIn.decode(SignInSession.self, from: Data(json.utf8))
      else {
        return .empty
      }
      return .session(session)
    }
  }

  init(read: @escaping @Sendable () -> KeychainStore.ReadResult, write: @escaping @Sendable (String?) -> Bool) {
    self.read = read
    self.write = write
  }

  /// An in-memory store for tests and UI-test runs.
  public static func inMemory() -> Self {
    let box = InMemoryAPIKeyStore()
    return Self(
      read: { box.current.map { .value($0) } ?? .absent },
      write: { box.save($0) }
    )
  }

  /// Stores `session`, or deletes the item for nil.
  @discardableResult
  public func save(_ session: SignInSession?) -> Bool {
    guard let session else {
      return write(nil)
    }
    guard let data = try? JSONEncoder.signIn.encode(session), let json = String(bytes: data, encoding: .utf8)
    else {
      return false
    }
    return write(json)
  }
}
