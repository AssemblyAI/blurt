# Blurt for Android (prototype)

A floating bubble that sits on the edge of the screen whenever a keyboard is up, the way Wispr
Flow's does. Tap it, speak, tap again: the words are typed into whatever field you were in.

It makes the same request as the Mac and iPhone apps: one streamed POST to AssemblyAI's dictation
route (`dictation.assemblyai.com/v1/transcribe/live`) carrying 16 kHz mono PCM, the text before the
cursor as `stt_prompt`, and the Mac's cleanup instruction as `llm_instruction`. It's Kotlin rather
than shared Swift: `DictationClient.kt` mirrors `Sources/BlurtEngine/STT/AssemblyAITranscriber.swift`,
and two files are verbatim copies of Swift: `CleanupInstruction.kt` (the base instruction and the
style preamble, from `Sources/BlurtEngine/STT/CleanupInstruction.swift`) and the presets in
`Styles.kt` (from `App/BlurtiOS/BlurtiOSCore/StylePreset.swift`). Change the Swift first and copy it
here.

## How it fits together

| File                           | What it does                                                                                                                                                                                                                                       |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MainActivity.kt`              | Setup: API key, microphone, display over other apps, typing into other apps, then the bubble switch and the style picker.                                                                                                                          |
| `BubbleService.kt`             | A microphone foreground service that floats the bubble while a keyboard is up. Tap toggles dictation, long-press cancels (or opens Blurt when idle), drag moves it with haptic ticks and it glides to an edge.                                     |
| `BubbleView.kt`                | The bubble (the b logo) in three looks: idle, recording (a green halo that follows your voice), transcribing.                                                                                                                                      |
| `MicRecorder.kt`               | `AudioRecord` at 16 kHz mono, 100 ms frames, capped at the route's 1200 s.                                                                                                                                                                         |
| `DictationClient.kt`           | The streamed multipart upload: `config` first, then audio frames as they're recorded. By the time you tap to stop, the upload is done.                                                                                                             |
| `BlurtAccessibilityService.kt` | Finds the focused text field across windows, reads the text before the cursor, and inserts the result with the right spacing. Also reports whether a keyboard is on screen. Without it, the words go to the clipboard and the bubble is always up. |
| `Styles.kt`                    | The output styles (None, Professional, Casual, Ultracasual, Custom), appended to the cleanup instruction.                                                                                                                                          |
| `OAuth.kt`, `Account.kt`       | Sign in with AssemblyAI: a port of `Sources/AssemblyAI/OAuth` and the engine's `AssemblyAIAccount` (PKCE, the key exchange, renewal, sign-out). See below.                                                                                         |
| `ApiKeyStore.kt`               | The API key, encrypted with an Android Keystore key.                                                                                                                                                                                               |

Two Android rules shape it:

- **The microphone service has to be started while Blurt is on screen.** Android won't let a
  service open the mic from the background otherwise, which is why the switch is in the app and the
  service isn't restarted by the system.
- **The bubble window can't take focus.** If it did, tapping it would pull focus out of the text
  field and there'd be nowhere to type the words.
- **Not every field tells the truth about its text.** Telegram's empty message box reports its
  "Message" placeholder as its text, with no hint and no cursor (selection -1). So a field that
  reports no cursor gets a paste, which the app puts at its own cursor, instead of a rewrite of the
  text it claims to hold.

The icons (`res/mipmap-*`, `res/drawable-nodpi`) are built from the b icon in the Blurt Figma file
(Mac Os › 256x256): its texture as the background and the b mark on top, at the rounded icon's
proportions. The notification icon is the mark's shape in white, because Android uses only its
alpha.

## One-time setup on your Mac

```bash
brew install openjdk@21 gradle
brew install --cask android-commandlinetools android-platform-tools
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
yes | sdkmanager --licenses
sdkmanager "platforms;android-35" "build-tools;35.0.0" "platform-tools"
```

Put the two `export` lines in `~/.zshrc` so every new terminal has them. Android Studio is optional
here, but its Logcat window is the easiest way to watch the app's logs.

## Install it on your phone

You install over USB with `adb`. Google's developer verification, which is rolling out from
September 2026, doesn't apply to `adb` installs, so you don't need a developer account for this.

1. On the phone, turn on **Developer options**: Settings › About phone, tap **Build number** seven
   times (on a Samsung it's Settings › About phone › Software information › Build number). Then in
   Developer options, turn on **USB debugging**. On a Samsung, also turn off **Auto Blocker**
   (Settings › Security and privacy) while you install, or it refuses installs over USB.
2. Plug the phone in and accept the "Allow USB debugging?" prompt on the phone.
   `adb devices` should list it.
3. Build and install, from this directory:

   ```bash
   ./gradlew installDebug
   ```

4. Open **Blurt** on the phone and go through the four steps, then turn on **Bubble**.

Wireless works too: Developer options › **Wireless debugging** › Pair device with pairing code, then
`adb pair <ip:port>` and `adb connect <ip:port>`.

### If "Blurt typing" is greyed out in Accessibility

Android blocks Accessibility for some apps installed from outside a store ("restricted setting").
Open Blurt's **App info** (the button on step 4), tap **⋮** in the top corner, choose **Allow
restricted settings**, then turn on Blurt typing again.

## Sign in with AssemblyAI

Off unless the build is configured, like the Mac's development builds (`App/Blurt/Config/SignIn.xcconfig`):
there is no production sign-in client yet, and the values for the sandbox one aren't in this repo. Add
them to `local.properties` (gitignored) in this directory, then rebuild:

```properties
blurt.oauth.clientId=…            # the Connected App's client id
blurt.oauth.authorizeUrl=https://…/dashboard/oauth/authorize
blurt.oauth.tokenUrl=https://…/v1/oauth2/token
blurt.oauth.apiOrigin=https://…   # serves /api/v2/oauth/api-key[/revoke]
blurt.oauth.dictationOrigin=https://…   # optional: the sandbox's dictation host; empty is production
```

They're the same values as the Mac's `SignIn.local.xcconfig`. Any missing or non-https value turns
sign-in off and the setup screen shows only the paste-a-key field.

The redirect is the Mac's own, `com.assemblyai.blurt://oauth/callback`, so the Connected App already
lists it; the manifest routes it back to the setup screen. The consent page opens in a Custom Tab.
The minted key is stored where a pasted one goes, and the session (the refresh token) beside it,
encrypted the same way. An app can't run the Mac's renewal timer, so a signed-in key renews when the
app opens and when the bubble starts a dictation, and at once when dictation reports it refused.

## Sharing it with other people

For a handful of testers, the free **limited distribution** account in the Android Developer Console
lets you register the app and install it on up to 20 devices without ID verification. The Play
Console's internal testing track is the next step after that. Both need a release build signed with
your own key, which this prototype doesn't set up yet.

## Not done yet

- Key terms, text shortcuts, more than one custom style, recent dictations in `stt_prompt`.
- A release signing config.
- Tests.
