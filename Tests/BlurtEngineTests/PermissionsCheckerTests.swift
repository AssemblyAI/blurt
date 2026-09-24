#if os(macOS)
  import Foundation
  import Testing

  @testable import BlurtEngine

  @Suite("PermissionsChecker")
  struct PermissionsCheckerTests {

    @Test("allGranted requires both microphone and accessibility")
    func allGrantedLogic() {
      #expect(PermissionStatus(microphone: true, accessibility: true).allGranted)
      #expect(!PermissionStatus(microphone: true, accessibility: false).allGranted)
      #expect(!PermissionStatus(microphone: false, accessibility: true).allGranted)
      #expect(!PermissionStatus(microphone: false, accessibility: false).allGranted)
    }

    @Test("PermissionStatus is value-equatable")
    func equatable() {
      #expect(
        PermissionStatus(microphone: true, accessibility: false)
          == PermissionStatus(microphone: true, accessibility: false))
      #expect(
        PermissionStatus(microphone: true, accessibility: false)
          != PermissionStatus(microphone: false, accessibility: false))
    }

    /// Every combination of the two probes, so the field each one feeds is pinned.
    static let probeCases: [(mic: Bool, accessibility: Bool)] = [
      (true, true), (true, false), (false, true), (false, false),
    ]

    @Test("check reports each probe in its own field", arguments: probeCases)
    func checkWiresProbesToFields(mic: Bool, accessibility: Bool) {
      // The one thing `check()` does that can be wrong: which probe feeds which
      // field. Driving both probes pins it — swap them and half these rows fail.
      #expect(
        PermissionsChecker.check(micGranted: { mic }, axTrusted: { accessibility })
          == PermissionStatus(microphone: mic, accessibility: accessibility))
    }

    @Test("check consults both probes exactly once")
    func checkReadsEachProbeOnce() {
      // Each real probe is a TCC read on the permission-poll timer; re-reading one
      // per call would double that traffic for a struct with two fields.
      let micReads = Counter()
      let axReads = Counter()
      _ = PermissionsChecker.check(
        micGranted: {
          _ = micReads.next()
          return true
        },
        axTrusted: {
          _ = axReads.next()
          return true
        })
      #expect(micReads.value == 1)
      #expect(axReads.value == 1)
    }

    /// Smoke tests, deliberately assertion-free: both entry points read
    /// process-global TCC state this host can't set, so all they can establish is
    /// that the real probes run without throwing or prompting. The behaviour they
    /// compose is covered above, against injected probes.
    @Suite("PermissionsChecker smoke")
    struct SmokeTests {
      @Test("the production check() runs against the real probes without prompting")
      func productionCheckRuns() {
        _ = PermissionsChecker.check()
      }

      @Test("forceAccessibilityActivity runs without prompting")
      @MainActor
      func forceAccessibilityActivityRuns() {
        // Best-effort, side-effect-light (a read-only AX query against another
        // process). This is the no-prompt half of the Accessibility flow —
        // `openAccessibilitySettings` adds the trust prompt.
        PermissionsChecker.forceAccessibilityActivity()
      }
    }
  }
#endif
