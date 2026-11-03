import BlurtEngine
import Foundation

/// The Advanced pane's local-insertion switch and the token a client has to
/// present: another process on this Mac hands Blurt a finished transcript and
/// Blurt inserts it through the very injector a dictation lands through
/// (`LoopbackInsertListener`).
///
/// **Off unless switched on, and never unauthenticated.** A listener that types
/// into whatever the user has focused is a keystroke-injection surface aimed at
/// their terminal, their password manager and their messages, so it is not a
/// default and it does not accept an unannounced client. See the listener for
/// what the token is and is not worth.
///
/// Read-only, like the engine's other switch stores (`MeetingAutoRecordStore`):
/// the Settings toggle binds `@AppStorage` to `enabledDefaultsKey`, and the
/// token row writes `tokenDefaultsKey` the same way.
///
/// The two keys are the app's rather than cases in the engine's `DefaultsKey`
/// because the feature is the app's — nothing in `BlurtEngine` knows there is a
/// socket, and the engine's roster is the sweep `PersistedSettings.resetAll`
/// walks. They still carry the host's defaults prefix, so a dev build and a
/// release each have their own switch, and Settings → Reset still clears them
/// (`InstallReset` removes the app's whole defaults domain, not just the
/// roster).
struct LoopbackInsertStore {
  /// `BlurtLoopbackInsert` under Blurt's identity. Unprefixed half frozen for
  /// the same reason `DefaultsKey`'s raw values are: renaming it silently
  /// switches the feature off for everyone who turned it on.
  static var enabledDefaultsKey: String { HostIdentity.current.defaultsPrefix + "LoopbackInsert" }
  /// `BlurtLoopbackInsertToken` — the shared secret, minted when the switch is
  /// first turned on and replaced by the Regenerate button.
  static var tokenDefaultsKey: String { HostIdentity.current.defaultsPrefix + "LoopbackInsertToken" }

  /// `~/Library/Application Support/<product>/insert.sock`, beside the saved
  /// history — whose URL is where that directory is spelled, so the two can't
  /// drift to different folders.
  ///
  /// A path under `~/Library`, which macOS keeps at mode 0700, so the socket is
  /// already out of every other user's reach before the 0600 the listener sets
  /// on the node itself.
  static var socketURL: URL {
    TranscriptStore.defaultURL.deletingLastPathComponent().appending(path: "insert.sock")
  }

  /// A fresh 256-bit token as 64 lowercase hex characters.
  ///
  /// `SystemRandomNumberGenerator` is the cryptographically secure one on every
  /// platform Swift ships (it wraps `arc4random_buf` here), so this needs no
  /// Security-framework call and no dependency.
  static func freshToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Whether the user has switched local insertion on. Unset reads as off.
  var isEnabled: Bool { defaults.bool(forKey: Self.enabledDefaultsKey) }

  /// The token a client must send as its first line, or empty when none has
  /// been minted. The listener refuses to bind on an empty one rather than
  /// falling open.
  var token: String { defaults.string(forKey: Self.tokenDefaultsKey) ?? "" }
}
