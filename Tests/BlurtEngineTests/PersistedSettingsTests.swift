import Foundation
import Testing

@testable import BlurtEngine

/// `PersistedSettings.allDefaultsKeys` exists so "add a store" and "add it to
/// every reset sweep" are the same edit. Pinning the roster here makes the
/// forgotten-half of that edit a test failure instead of a silently stale sweep.
@Suite("PersistedSettings")
struct PersistedSettingsTests {
  @Test("the reset roster names every engine store's defaults key")
  func rosterCoversEveryStore() {
    #expect(PersistedSettings.allDefaultsKeys.contains(TriggerKeyStore.defaultsKey))
    #expect(PersistedSettings.allDefaultsKeys.contains(SoundPackStore.defaultsKey))
    #expect(PersistedSettings.allDefaultsKeys.contains(KeyTermsStore.defaultsKey))
    #expect(PersistedSettings.allDefaultsKeys.contains(DeveloperModeStore.defaultsKey))
    // Enhanced transcripts default to ON, so its key matters to the sweep in
    // the other direction too: a stray `false` surviving a reset would leave a
    // "clean" install pasting verbatim transcripts.
    #expect(PersistedSettings.allDefaultsKeys.contains(EnhancedTranscriptsStore.defaultsKey))
    // OverlayOriginStore persists a point, so it contributes two keys rather
    // than one. Both belong to the sweep: while they were private to
    // `OverlayWindowController`, no reset knew about them and a pill dragged
    // during a UI-test run survived into later runs.
    #expect(PersistedSettings.allDefaultsKeys.contains(OverlayOriginStore.xDefaultsKey))
    #expect(PersistedSettings.allDefaultsKeys.contains(OverlayOriginStore.yDefaultsKey))
    // The launch update check's throttle: left out of the sweep, a UI-test run
    // (or a "clean install") would inherit yesterday's stamp and skip the check.
    #expect(PersistedSettings.allDefaultsKeys.contains(LastUpdateCheckStore.defaultsKey))
  }

  @Test("the roster carries no stale or duplicate keys")
  func rosterHasNoStrays() {
    // Exactly the seven known stores' keys (OverlayOriginStore contributes two):
    // a removed store must leave the roster in the same change, and a key listed
    // twice would hint at a copy-paste slip.
    #expect(PersistedSettings.allDefaultsKeys.count == 8)
    #expect(Set(PersistedSettings.allDefaultsKeys).count == PersistedSettings.allDefaultsKeys.count)
  }

  @Test("resetAll clears every roster key and leaves unrelated ones alone")
  func resetAllClearsTheRoster() {
    let defaults = freshDefaults()
    for key in PersistedSettings.allDefaultsKeys {
      defaults.set("stale", forKey: key)
    }
    // The signing-identity marker is deliberately outside the roster — it records
    // what the TCC migration has already done, and clearing it would re-run the
    // reset.
    defaults.set("TEAMID", forKey: SigningIdentityMigration.lastSigningIdentityDefaultsKey)

    PersistedSettings.resetAll(in: defaults)

    for key in PersistedSettings.allDefaultsKeys {
      #expect(defaults.object(forKey: key) == nil, "\(key) should have been cleared")
    }
    #expect(
      defaults.string(forKey: SigningIdentityMigration.lastSigningIdentityDefaultsKey) == "TEAMID")
  }
}
