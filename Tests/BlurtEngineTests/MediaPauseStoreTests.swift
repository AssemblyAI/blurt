import Foundation
import Testing

@testable import BlurtEngine

@Suite("MediaPauseStore")
struct MediaPauseStoreTests {
  /// Defaults the developer-mode switch on, as the Advanced pane's toggle would.
  private func developerDefaults() -> UserDefaults {
    let defaults = freshDefaults()
    defaults.set(true, forKey: DeveloperModeStore.defaultsKey)
    return defaults
  }

  @Test("off while developer mode is off, whatever its own switch says")
  func offOutsideDeveloperMode() {
    // A developer option on trial: an untouched install pauses nothing.
    let defaults = freshDefaults()
    let store = MediaPauseStore(defaults: defaults)
    #expect(!store.isEnabled)
    defaults.set(true, forKey: MediaPauseStore.defaultsKey)
    #expect(!store.isEnabled)
  }

  @Test("within developer mode, defaults to on when unset")
  func defaultsToOnInDeveloperMode() {
    // Quieting the music you're dictating over is the useful default, and the
    // scripted path can't start anything unbidden, so it's safe to default on.
    #expect(MediaPauseStore(defaults: developerDefaults()).isEnabled)
  }

  /// The store is read-only, so what it has to agree with is the slots the Settings
  /// toggles write through `@AppStorage` — which is what this seeds, rather than a
  /// setter no production code calls.
  @Test("reads back both switches the Settings toggles write")
  func readsBackTheToggledSlots() {
    let defaults = developerDefaults()
    let store = MediaPauseStore(defaults: defaults)
    defaults.set(false, forKey: MediaPauseStore.defaultsKey)
    #expect(!store.isEnabled)
    // Same instance: the store reads through to `defaults` on every access, which is
    // what lets the pause controller pick a change up on the very next dictation.
    defaults.set(true, forKey: MediaPauseStore.defaultsKey)
    #expect(store.isEnabled)
    defaults.set(false, forKey: DeveloperModeStore.defaultsKey)
    #expect(!store.isEnabled)
  }

  @Test("an explicit opt-out is distinguishable from unset")
  func optOutIsNotMistakenForUnset() {
    // The presence check is the whole point of the inverted default: writing `false`
    // must not read back the same as never having chosen.
    let defaults = developerDefaults()
    defaults.set(false, forKey: MediaPauseStore.defaultsKey)
    #expect(defaults.object(forKey: MediaPauseStore.defaultsKey) as? Bool == false)
    #expect(!MediaPauseStore(defaults: defaults).isEnabled)
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
