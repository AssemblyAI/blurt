import Foundation
import Testing

@testable import BlurtEngine

@Suite("MediaPauseStore")
struct MediaPauseStoreTests {
  @Test("defaults to off when unset")
  func defaultsToOff() {
    #expect(!MediaPauseStore(defaults: freshDefaults()).isEnabled)
  }

  /// The store is read-only, so what it has to agree with is the slot the Settings
  /// toggle writes through `@AppStorage` — which is what this seeds, rather than a
  /// setter no production code calls.
  @Test("reads back the switch the Settings toggle writes")
  func readsBackTheToggledSlot() {
    let defaults = freshDefaults()
    let store = MediaPauseStore(defaults: defaults)
    defaults.set(true, forKey: MediaPauseStore.defaultsKey)
    #expect(store.isEnabled)
    // Same instance: the store reads through to `defaults` on every access, which is
    // what lets the pause controller pick a change up on the very next dictation.
    defaults.set(false, forKey: MediaPauseStore.defaultsKey)
    #expect(!store.isEnabled)
  }

  @Test("developer mode doesn't turn it on, or off")
  func independentOfDeveloperMode() {
    let defaults = freshDefaults()
    let store = MediaPauseStore(defaults: defaults)
    defaults.set(true, forKey: DeveloperModeStore.defaultsKey)
    #expect(!store.isEnabled)
    defaults.set(true, forKey: MediaPauseStore.defaultsKey)
    defaults.set(false, forKey: DeveloperModeStore.defaultsKey)
    #expect(store.isEnabled)
  }

  @Test("the scriptable players are the two with a player-state vocabulary")
  func playerRoster() {
    // Each entry costs the user an automation-consent prompt and needs its scripting
    // dictionary verified, so the roster is deliberately closed. Browsers are
    // excluded on purpose — see MediaPlayerApp's doc.
    #expect(MediaPlayerApp.allCases.map(\.rawValue) == ["Spotify", "Music"])
    #expect(MediaPlayerApp.allCases.map(\.bundleIdentifier) == ["com.spotify.client", "com.apple.Music"])
  }

  @Test("only running players are scripted, in roster order")
  func runningPlayers() {
    #expect(MediaPlayerApp.running(among: ["com.apple.finder", nil]).isEmpty)
    #expect(MediaPlayerApp.running(among: ["com.apple.Music"]) == [.appleMusic])
    #expect(MediaPlayerApp.running(among: ["com.apple.Music", "com.spotify.client"]) == [.spotify, .appleMusic])
  }

  /// AppleScript resolves app terminology at compile time, so a script naming an
  /// uninstalled app fails whole: each player's script must name only that player.
  @Test("each player's scripts name only that player")
  func scriptsNameOnePlayer() {
    for player in MediaPlayerApp.allCases {
      for script in [player.pauseScript, player.resumeScript] {
        for other in MediaPlayerApp.allCases where other != player {
          #expect(!script.contains("\"\(other.rawValue)\""))
        }
        #expect(script.contains("application \"\(player.rawValue)\" is running"))
      }
    }
  }

  @Test("pause acts only on a playing player, resume only on a still-paused one")
  func scriptsAreConditional() {
    #expect(MediaPlayerApp.spotify.pauseScript.contains("if player state is playing then"))
    #expect(MediaPlayerApp.spotify.resumeScript.contains("if player state is paused then play"))
  }
}
