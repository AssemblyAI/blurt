/// The grants a Blurt install needs, as one reading. A pure value — two Bools
/// and their derivations — consumed by the portable `SetupReadiness` policy,
/// which is why it lives apart from `PermissionsChecker`: only *reading* the
/// grants needs the macOS-only TCC probes, and the rule that decides what
/// "ready" means must build on every platform the engine does.
public struct PermissionStatus: Equatable, Sendable {
  public let microphone: Bool
  public let accessibility: Bool

  public init(microphone: Bool, accessibility: Bool) {
    self.microphone = microphone
    self.accessibility = accessibility
  }

  public var allGranted: Bool { microphone && accessibility }

  /// True when `previous` had every permission and this reading no longer does —
  /// i.e. the user revoked one in System Settings, possibly while no window was
  /// open. The shell reacts by pulling them back into onboarding rather than
  /// leaving a dead overlay, so this is a behavioural edge worth a test; it lives
  /// next to `allGranted`, the derivation it's built from, rather than being
  /// spelled out at the one call site that watches for it.
  public func lostGrant(since previous: PermissionStatus) -> Bool {
    previous.allGranted && !allGranted
  }
}
