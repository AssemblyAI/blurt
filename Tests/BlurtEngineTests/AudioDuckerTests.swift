import Synchronization
import Testing

@testable import BlurtEngine

/// Exercises the duck/restore decisions through the injected `Client` seam and
/// in-memory persistence closures. Every closure is substituted — no test here
/// may touch a real output device or `UserDefaults` — and the device is modeled
/// as a live volume slot, so "restored", "left alone", and "never touched" are
/// distinguishable outcomes rather than call counts.
@Suite("AudioDucker")
struct AudioDuckerTests {
  /// The device and the persisted slot a scenario runs against: a settable
  /// output volume (nil = no duckable device), the pending-restore slot the
  /// persistence closures share, and a read count so "made no HAL call at all"
  /// is assertable for the opted-out case.
  private final class Rig: Sendable {
    private let volume: Mutex<Float?>
    private let deviceUID: Mutex<String?>
    private let pending = Mutex<AudioDucker.PendingRestore?>(nil)
    private let reads = Mutex(0)

    init(volume: Float?, deviceUID: String? = "device-A") {
      self.volume = Mutex(volume)
      self.deviceUID = Mutex(deviceUID)
    }

    var currentVolume: Float? { volume.withLock { $0 } }
    var pendingRestore: AudioDucker.PendingRestore? { pending.withLock { $0 } }
    var volumeReads: Int { reads.withLock { $0 } }

    func setVolume(_ newValue: Float?) {
      volume.withLock { $0 = newValue }
    }

    /// The user picks a different default output mid-scenario: a new identity
    /// with its own volume, as `AudioDucker`'s client would then see.
    func switchDevice(to uid: String?, volume newVolume: Float?) {
      deviceUID.withLock { $0 = uid }
      volume.withLock { $0 = newVolume }
    }

    /// A ducker over this rig. Separate from the rig so a scenario can build a
    /// second ducker on the same rig — that is the crash-recovery shape: a new
    /// launch's ducker, same persisted slot, same device. `quantize` models a
    /// device with coarse volume steps: every set lands on the nearest step
    /// instead of the exact value.
    func makeDucker(
      enabled: Bool = true, quantize: @escaping @Sendable (Float) -> Float = { $0 }
    ) -> AudioDucker {
      AudioDucker(
        client: AudioDucker.Client(
          outputVolume: { [self] in
            reads.withLock { $0 += 1 }
            return volume.withLock { $0 }
          },
          setOutputVolume: { [self] newValue in volume.withLock { $0 = quantize(newValue) } },
          defaultOutputDeviceUID: { [self] in deviceUID.withLock { $0 } }),
        isEnabled: { enabled },
        readPendingRestore: { [self] in pending.withLock { $0 } },
        writePendingRestore: { [self] newValue in pending.withLock { $0 = newValue } })
    }
  }

  @Test("ducks to the fraction and restores the saved volume")
  func ducksAndRestores() {
    let rig = Rig(volume: 0.8)
    let ducker = rig.makeDucker()
    ducker.duckIfEnabled()
    #expect(rig.currentVolume == 0.8 * AudioDucker.duckFraction)
    #expect(ducker.isOutputDucked)
    ducker.restoreIfDucked()
    #expect(rig.currentVolume == 0.8)
    #expect(!ducker.isOutputDucked)
  }

  @Test("disabled touches nothing — not even a volume read")
  func disabledTouchesNothing() {
    let rig = Rig(volume: 0.8)
    let ducker = rig.makeDucker(enabled: false)
    ducker.duckIfEnabled()
    ducker.restoreIfDucked()
    // The whole point of default-off: with the toggle off the HAL is never
    // asked anything, and the volume never moves.
    #expect(rig.volumeReads == 0)
    #expect(rig.currentVolume == 0.8)
    #expect(rig.pendingRestore == nil)
  }

  @Test(
    "no duckable output volume means no duck and nothing owed",
    arguments: [Float?.none, 0])
  func unduckableVolumeMeansNoDuck(volume: Float?) {
    // nil is "no default output device, or its volume isn't settable"; 0 has
    // nothing left to lower — and a saved volume of 0 would make the restore a
    // pointless write.
    let rig = Rig(volume: volume)
    let ducker = rig.makeDucker()
    ducker.duckIfEnabled()
    #expect(rig.currentVolume == volume)
    #expect(rig.pendingRestore == nil)
    #expect(!ducker.isOutputDucked)
  }

  @Test("a volume the user moved mid-dictation is left alone")
  func touchedVolumeIsLeftAlone() {
    let rig = Rig(volume: 0.8)
    let ducker = rig.makeDucker()
    ducker.duckIfEnabled()
    // The user reaches for the volume keys mid-dictation: their choice stands,
    // and the end must not stomp it — but the owed slot is still consumed, so
    // nothing dangles into the next dictation.
    rig.setVolume(0.5)
    ducker.restoreIfDucked()
    #expect(rig.currentVolume == 0.5)
    #expect(rig.pendingRestore == nil)
  }

  @Test("an end with no matching duck is a no-op")
  func endWithoutDuckIsANoOp() {
    let rig = Rig(volume: 0.8)
    let ducker = rig.makeDucker()
    ducker.restoreIfDucked()
    // The initial `.idle` render of every clean launch lands here: no slot, no
    // HAL call, no volume change.
    #expect(rig.volumeReads == 0)
    #expect(rig.currentVolume == 0.8)
  }

  @Test("a duck is restored at most once")
  func restoresAtMostOnce() {
    let rig = Rig(volume: 0.8)
    let ducker = rig.makeDucker()
    ducker.duckIfEnabled()
    ducker.restoreIfDucked()
    // The user turns it down by hand after the dictation; the second terminal
    // render (phases keep arriving) finds the slot consumed and leaves it be.
    rig.setVolume(0.8 * AudioDucker.duckFraction)
    ducker.restoreIfDucked()
    #expect(rig.currentVolume == 0.8 * AudioDucker.duckFraction)
  }

  @Test("a begin that finds a duck in flight doesn't re-duck")
  func beginWithPendingRestoreLeavesItAlone() {
    let rig = Rig(volume: 0.8)
    let ducker = rig.makeDucker()
    ducker.duckIfEnabled()
    ducker.duckIfEnabled()
    // Re-ducking would overwrite `saved` with the already-ducked volume, and
    // the restore would then "restore" to quiet. The slot must keep the first
    // duck's truth.
    #expect(rig.pendingRestore?.saved == 0.8)
    ducker.restoreIfDucked()
    #expect(rig.currentVolume == 0.8)
  }

  @Test("the ducked value tracks where the device actually landed")
  func duckedValueTracksTheDevice() {
    // A device with coarse volume steps: every set lands on the nearest 1/16.
    // 0.75 is a step itself, so only the ducked value gets moved by the device.
    let rig = Rig(volume: 0.75)
    let quantize: @Sendable (Float) -> Float = { ($0 * 16).rounded() / 16 }
    let ducker = rig.makeDucker(quantize: quantize)
    ducker.duckIfEnabled()
    // 0.75 × 0.2 = 0.15 lands at 0.125; the slot must record the device's
    // truth, or the restore's "still where we left it?" check — a whole
    // volume-key step away from our arithmetic — could never pass.
    #expect(rig.pendingRestore?.ducked == quantize(0.75 * AudioDucker.duckFraction))
    ducker.restoreIfDucked()
    #expect(rig.currentVolume == 0.75)
  }

  @Test("a restore never moves a device the duck didn't lower")
  func deviceSwitchIsNeverRestored() {
    let rig = Rig(volume: 1.0)
    let ducker = rig.makeDucker()
    ducker.duckIfEnabled()
    // The user switches the default output mid-dictation to a device that
    // happens to sit exactly at the ducked value — the one switch the volume
    // comparison alone cannot tell from "untouched". The UID recorded at duck
    // time is what keeps the new device's volume from being yanked to the old
    // device's saved level; the owed slot is still consumed.
    rig.switchDevice(to: "device-B", volume: 1.0 * AudioDucker.duckFraction)
    ducker.restoreIfDucked()
    #expect(rig.currentVolume == 1.0 * AudioDucker.duckFraction)
    #expect(rig.pendingRestore == nil)
  }

  @Test("a duck recorded without a device identity still restores on volume match")
  func nilDeviceIdentityFallsBackToVolumeMatch() {
    // The UID read can fail while the volume calls work; the slot then carries
    // no identity and the touched-volume rule alone decides, as before.
    let rig = Rig(volume: 0.8, deviceUID: nil)
    let ducker = rig.makeDucker()
    ducker.duckIfEnabled()
    ducker.restoreIfDucked()
    #expect(rig.currentVolume == 0.8)
    #expect(rig.pendingRestore == nil)
  }

  @Test("a crash mid-dictation is settled at the next launch")
  func crashIsSettledAtNextLaunch() {
    let rig = Rig(volume: 0.8)
    rig.makeDucker().duckIfEnabled()
    // The process dies here: the ducked volume and the persisted slot are all
    // that survive. The next launch's ducker — same persistence, fresh
    // instance — restores on its initial terminal render.
    rig.makeDucker().restoreIfDucked()
    #expect(rig.currentVolume == 0.8)
    #expect(rig.pendingRestore == nil)
  }

  @Test("a crash whose leftover volume the user already fixed is only cleared")
  func staleCrashSlotIsClearedWithoutRestoring() {
    let rig = Rig(volume: 0.8)
    rig.makeDucker().duckIfEnabled()
    // Between the crash and the relaunch the user put the volume where they
    // want it; the leftover slot must be consumed without moving anything.
    rig.setVolume(1.0)
    rig.makeDucker().restoreIfDucked()
    #expect(rig.currentVolume == 1.0)
    #expect(rig.pendingRestore == nil)
  }

  @Test("the public entry points run the same decisions, in order, off the caller")
  func publicEntryPointsRunTheDecisions() async {
    let rig = Rig(volume: 0.8)
    let ducker = rig.makeDucker()
    ducker.dictationBegan()
    ducker.dictationEnded()
    // Both calls return immediately; the queue is serial and FIFO, so once the
    // volume is back the duck must have run ahead of the restore (a restore
    // that jumped the queue would have found nothing owed and left the volume
    // ducked). Bounded poll rather than a bare spin, so a regression fails
    // instead of hanging.
    for _ in 0..<2_000 where rig.currentVolume != 0.8 {
      try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(rig.currentVolume == 0.8)
    #expect(rig.volumeReads > 0)
  }
}
