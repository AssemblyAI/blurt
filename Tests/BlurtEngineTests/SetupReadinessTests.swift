import Testing

@testable import BlurtEngine

/// The first-run setup gate and its poll cadence. Both lived in
/// `WizardController` — an app-shell type with no test target — so the readiness
/// rule and the revocation edge that pulls the user back into onboarding were
/// uncovered.
@Suite("SetupReadiness")
struct SetupReadinessTests {
  private let all = PermissionStatus(microphone: true, accessibility: true)
  private let noMic = PermissionStatus(microphone: false, accessibility: true)
  private let noAX = PermissionStatus(microphone: true, accessibility: false)
  private let neither = PermissionStatus(microphone: false, accessibility: false)

  @Test("ready needs every permission and a key")
  func readyRequiresEverything() {
    #expect(SetupReadiness.isReady(permissions: all, hasAPIKey: true))
  }

  @Test("any missing input keeps setup unfinished")
  func anyMissingInputBlocks() {
    #expect(!SetupReadiness.isReady(permissions: all, hasAPIKey: false))
    #expect(!SetupReadiness.isReady(permissions: noMic, hasAPIKey: true))
    #expect(!SetupReadiness.isReady(permissions: noAX, hasAPIKey: true))
    #expect(!SetupReadiness.isReady(permissions: neither, hasAPIKey: false))
  }

  @Test("the poll coasts once configured and stays brisk while setting up")
  func pollCadence() {
    #expect(SetupReadiness.pollInterval(isReady: false) == SetupReadiness.settingUpPollInterval)
    #expect(SetupReadiness.pollInterval(isReady: true) == SetupReadiness.readyPollInterval)
    // The direction is the point: polling a configured app as often as one being
    // set up wakes the main actor every second for the app's whole life.
    #expect(SetupReadiness.readyPollInterval > SetupReadiness.settingUpPollInterval)
  }

  @Test("losing a granted permission is detected")
  func revocationDetected() {
    // The edge that pulls a configured app back into onboarding.
    #expect(noMic.lostGrant(since: all))
    #expect(noAX.lostGrant(since: all))
    #expect(neither.lostGrant(since: all))
  }

  @Test("a steady state is not a revocation")
  func steadyStateIsNotRevocation() {
    // Every poll tick passes through this; treating no-change as a revocation
    // would surface the setup window on a timer.
    #expect(!all.lostGrant(since: all))
    #expect(!noMic.lostGrant(since: noMic))
  }

  @Test("a permission granted, or one still missing, is not a revocation")
  func grantIsNotRevocation() {
    // Going the other way (setup progressing) must not fire.
    #expect(!all.lostGrant(since: noMic))
    // Never fully granted to begin with, so nothing was lost — the user is still
    // mid-onboarding and shouldn't be "kicked back" to where they already are.
    #expect(!neither.lostGrant(since: noMic))
  }
}
