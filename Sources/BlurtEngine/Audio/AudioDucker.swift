import Dispatch

/// Lowers the system output volume while a dictation is in flight and restores
/// it when the dictation ends — pasted, copied, failed, or cancelled — so music
/// or a video keeps playing (quietly, and still advancing) instead of bleeding
/// into the microphone. Lower-and-restore, deliberately not mute: the owner's
/// direction, after an AppleScript pause-the-player approach was reverted —
/// ducking the *output device* covers every audio source at once, needs no
/// Apple Events entitlement and raises no Automation prompt.
///
/// Opt-in via `AudioDuckStore` (off by default), re-read at each dictation.
/// Three rules keep it polite:
///
/// - **Restore only what we ducked.** The volume goes back only when it still
///   sits where the duck left it; a user who touched the volume keys
///   mid-dictation has taken the wheel, and their choice stands. (A default
///   output *device* change mid-dictation reads the same way — the new
///   device's volume won't match the ducked value — which is the conservative
///   answer: never move a volume we didn't set.)
/// - **Restore survives a crash.** What the duck owes is persisted
///   (`AudioDuckStore.pendingRestore`) *before* the volume moves, so a run
///   that dies mid-dictation still restores: the next launch's very first
///   render is a terminal phase (`DictationSession.phaseStream` yields the
///   current — idle — phase immediately), and `dictationEnded()` on it settles
///   the leftover slot under the same touched-volume rule.
/// - **A duck happens at most once at a time.** A begin that finds a pending
///   restore leaves it alone rather than re-ducking — overwriting the slot
///   would record the already-ducked volume as the one to restore to.
///
/// Both entry points are fire-and-forget onto a private serial queue: HAL
/// property calls are fast, but they are still IPC into `coreaudiod`, so they
/// stay off the press-to-record path (the reasoning on
/// `DictationSession.contextQueue`), and the serial queue keeps a dictation's
/// duck ahead of its restore across the hop. Nothing on that path ever awaits
/// this type.
public final class AudioDucker: Sendable {
  /// The restore a duck owes: the volume to put back (`saved`) and the volume
  /// the duck actually landed at (`ducked`) — read back from the device rather
  /// than assumed, because hardware quantizes (a device with coarse volume
  /// steps stores the nearest step, and the touched-volume comparison must be
  /// against what the device really holds).
  struct PendingRestore: Equatable, Sendable {
    let saved: Float
    let ducked: Float
  }

  /// How far a duck lowers the volume: to this fraction of what the user had.
  /// Proportional rather than a flat floor so "quiet" scales with the user's
  /// own level — someone listening at 0.9 ducks to 0.18, someone at 0.3 to
  /// 0.06. 0.2 keeps playback audible enough to notice it never stopped while
  /// taking it well out of the microphone's way. (VoiceInk was the model for
  /// the mechanism, but it *mutes*; the fraction is our own choice, made
  /// against the same "keep it obviously still playing" goal.)
  static let duckFraction: Float = 0.2

  /// How close the current volume must sit to the ducked value to count as
  /// untouched. The ducked value is read back from the device, so equality is
  /// the expected case; the tolerance absorbs Float32 round-tripping through
  /// `UserDefaults`. One volume-key step is 1/16 ≈ 0.06, comfortably outside
  /// it, so a single tap of the keys reads as "the user took the wheel".
  static let volumeTolerance: Float = 0.01

  private let client: Client
  private let isEnabled: @Sendable () -> Bool
  private let readPendingRestore: @Sendable () -> PendingRestore?
  private let writePendingRestore: @Sendable (PendingRestore?) -> Void
  /// Serial, so a dictation's duck always lands before its restore — the host
  /// hands us the phases in order, and this keeps them in order across the hop.
  private let queue = DispatchQueue(
    label: HostIdentity.current.queueLabel("AudioDuck"), qos: .userInitiated)

  /// The real HAL client and the Settings switch — what the app uses.
  public convenience init() {
    self.init(client: .production)
  }

  /// Seam-injected for tests (see `Client`). The closures default to the
  /// production store so `AudioDuckStore`'s members keep production readers;
  /// `isEnabled` is a closure so each dictation re-reads the toggle, and the
  /// pending-restore pair is closures rather than a held store so this class
  /// stays `Sendable` without capturing `UserDefaults`.
  init(
    client: Client,
    isEnabled: @escaping @Sendable () -> Bool = { AudioDuckStore().isEnabled },
    readPendingRestore: @escaping @Sendable () -> PendingRestore? = {
      AudioDuckStore().pendingRestore
    },
    writePendingRestore: @escaping @Sendable (PendingRestore?) -> Void = {
      AudioDuckStore().pendingRestore = $0
    }
  ) {
    self.client = client
    self.isEnabled = isEnabled
    self.readPendingRestore = readPendingRestore
    self.writePendingRestore = writePendingRestore
  }

  /// Call once per dictation, when the press is accepted. Fire-and-forget:
  /// returns immediately, the HAL work runs on the ducker's own queue.
  public func dictationBegan() {
    queue.async { self.duckIfEnabled() }
  }

  /// Call on every terminal phase. Fire-and-forget, and free when nothing is
  /// owed (the pending slot is read before the device is so much as looked
  /// at), so hosts can call it for every terminal render — including the
  /// initial `.idle`, which is exactly how a crash's leftover duck gets
  /// restored at the next launch.
  public func dictationEnded() {
    queue.async { self.restoreIfDucked() }
  }

  /// Whether a duck is currently in flight — what `CueSoundPlayer` reads to
  /// play the chimes at compensated gain while the output is lowered. A cheap
  /// `UserDefaults` probe, safe from any thread.
  public var isOutputDucked: Bool {
    readPendingRestore() != nil
  }

  /// The decision half of `dictationBegan()`, synchronous for the unit tests.
  /// `isEnabled` is checked before the device is touched, so the opted-out
  /// case makes no HAL call at all. A nil volume — no default output device,
  /// or one whose main volume can't be set (some HDMI and AirPlay outputs) —
  /// means no duck and nothing owed; so does a volume of 0, which has nothing
  /// left to lower.
  func duckIfEnabled() {
    guard isEnabled(), readPendingRestore() == nil,
      let saved = client.outputVolume(), saved > 0
    else { return }
    let target = saved * Self.duckFraction
    // Persist what we owe *before* moving the volume: a crash between the two
    // writes must strand a stale slot (settled harmlessly at next launch by
    // the touched-volume rule), never a lowered volume with no record of it.
    writePendingRestore(PendingRestore(saved: saved, ducked: target))
    client.setOutputVolume(target)
    // Re-read where the duck actually landed — hardware quantizes — so the
    // restore's "still where we left it?" comparison is against the device's
    // truth, not our arithmetic.
    if let landed = client.outputVolume(), landed != target {
      writePendingRestore(PendingRestore(saved: saved, ducked: landed))
    }
  }

  /// The decision half of `dictationEnded()`. The pending slot is consumed
  /// either way — a restore happens at most once per duck — but the volume is
  /// only put back when it still sits where the duck left it: a user who
  /// moved it mid-dictation (or switched output devices, which reads the
  /// same) keeps their choice.
  ///
  /// The slot is cleared *after* the volume moves, mirroring the duck's
  /// persist-before-move: a crash between the two leaves a slot whose ducked
  /// value no longer matches the restored volume, which the next launch's
  /// touched-volume check clears without moving anything — where the other
  /// order would strand the user at the ducked volume with no record of it.
  func restoreIfDucked() {
    guard let pending = readPendingRestore() else { return }
    if let current = client.outputVolume(), abs(current - pending.ducked) <= Self.volumeTolerance {
      client.setOutputVolume(pending.saved)
    }
    writePendingRestore(nil)
  }
}
