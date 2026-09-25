# Blurt for iPhone — design

The iPhone app and its keyboard are the Mac app's design on a phone: the same
ink, the same two greens, the same orb, the same status pill. Nothing here was
invented; every number traces to a Mac source file, and where the phone needed
something the Mac has no equivalent for, this file says what was decided and
why. The keyboard is done; the app's own screens are next (see the end).

Source of truth on the Mac side: `App/Blurt/Blurt/Branding/BlurtBrand.swift`
(tokens, orb gradient), `App/Blurt/Blurt/Overlay/OverlayView.swift` and
`OverlayPillContent.swift` (the pill), `BrandOrb.swift` (the orb),
`Sources/BlurtEngine/Pipeline/MeterBarGeometry.swift` (the meter, unit-tested).
The phone reads the meter and the ring's rotation straight from the engine, so
they cannot drift from the Mac's.

## Reproducing it

Every layout and state renders inside the app, from a launch argument, so a
screenshot never depends on tapping through Notes:

```bash
BLURT_LAUNCH_ARGS="-BlurtGallery panel idle,recording,processing" scripts/ios-sim.sh --screenshot panel.png
BLURT_LAUNCH_ARGS="-BlurtGallery slimBar off,start,idle,connecting,recording,processing,pasted,copied,error" scripts/ios-sim.sh --screenshot slim.png
BLURT_LAUNCH_ARGS="-BlurtGallery full idle,recording,error" scripts/ios-sim.sh --screenshot full.png
```

Layouts: `slimBar`, `panel`, `full`. States: `off` (no Full Access), `start`
(the app isn't listening), then the pipeline's `idle`, `connecting`,
`recording` (level 0.62), `processing`, `pasted`, `copied`, `error`. The
gallery is `BlurtiOS/Sources/KeyboardGalleryView.swift`, debug builds only;
the keyboard's sources are compiled into the app for it (`project.yml`).

## Two looks (`KeyboardTheme`, `BlurtKeyboard/Sources/KeyboardPalette.swift`)

People are used to the iPhone's keyboard, so the keys can look exactly like it.
The **look** is a setting beside the layout, in the app's Keyboard section:

| Look     | Surface and keys                                                                                                                                                                               |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `blurt`  | The ink surface and tokens below, in every appearance. Gaps 5, rows 8, margin 8.                                                                                                               |
| `system` | The iPhone keyboard's own palette, light or dark with the app being typed in (its field's `keyboardAppearance`, else the app's style). Gaps 6, rows 11, margin 3, a 1 pt drop under every key. |

System light: surface `#D1D5DB`, letter keys white, modifiers `#ADB3BC`, drop
`#898A8D`, black legends. System dark: surface `#2B2B2B`, keys `#6B6B6B`,
modifiers `#464646`, drop `#0D0D0D`, white legends. Radius 5 (Blurt: 6). The
status pill and the orb stay Blurt's in both — the look is about the keys.
The gallery's last argument picks it: `blurt` (default), `light`, `dark`.

The full layout follows the iPhone's geometry in both looks: ten letter keys
across at one width (`(width − 9·gap) / 10`), the middle row centred, shift
and delete taking what seven letters leave (twice the gap away from them),
then 123 · globe · space · mic · return, return two modifiers wide. Letters
pop up while pressed (a 32 pt copy 58 pt above the key, typed on release);
shift comes on by itself at the start of a sentence — or of every word, or
always — as the field's `autocapitalizationType` asks, and goes off after
one letter; a second space within 450 ms of the first, after a word, becomes
". ". Not yet: autocorrect and the suggestion bar.

## Hands-free

A toggle in the same section: with it on, a dictation starts the moment the
keyboard comes up in a text field — the same synthetic tap through the
engine's gate, so it latches and the next tap of the mic stops it. Only when
the app is listening and nothing is in flight; otherwise the pill says what to
do, and the first tap opens Blurt as usual. It fires on the keyboard's
appearance, not on every field change while it stays up.

## Tokens (`Shared/BlurtBrand.swift`)

| Token             | Value       | Use                                                         |
| ----------------- | ----------- | ----------------------------------------------------------- |
| `green`           | `#01762F`   | the wordmark green, light chrome (the app's accent)         |
| `greenOnDark`     | `#67AD82`   | pill text and meter, the ring, anything green on ink        |
| `ink`             | `#1D1B16`   | the pill's body in every state; the keyboard's surface      |
| `errorOrange`     | `#E67F36`   | the error word — never a red body                           |
| `key`             | `#33302A`   | an ordinary key on the ink surface (one step up)            |
| `keyDark`         | `#26231E`   | modifier keys: shift, delete, globe, return, 123, cancel    |
| `keyText`         | `#F2EEE6`   | key legends: warm white on warm ink                         |
| `orbGradient`     | 8 stops     | the design's own (`App elements/Recording.svg`), bottom→top |
| `orbRingGradient` | green→white | the ring, top-leading to bottom-trailing                    |

The keyboard is a **fixed dark surface** in both appearances, for the reason
the Mac pill is: it floats over whichever app the user is typing in, so it
cannot take a cue from that app, and it must read the same over a white Notes
page and a black Messages thread. Nothing on it uses `accent`.

## Type

Status line: 11 pt semibold, uppercase, tracking 1.1 (the Mac's 9 pt / 0.9,
scaled for a phone at arm's length). Key legends: letters 22 pt regular,
everything else 16 pt medium. System font throughout.

## Components (`BlurtKeyboard/Sources/`)

**Status pill** (`StatusPill.swift`) — 36 pt capsule (Mac: 28), ink body, 12 %
white 1 pt rim, shadow black 25 % radius 10 offset y 3; inset 12, gap 8; orb
21.6 pt (the Mac's 24-in-40 ratio). Content by state:

| State                  | Pill                                           | Mic key                         |
| ---------------------- | ---------------------------------------------- | ------------------------------- |
| no Full Access (`off`) | `ALLOW FULL ACCESS` in orange, alone           | orb dimmed (saturation 0.35)    |
| app not listening      | orb still · `TAP THE MIC TO START`             | orb dimmed; a tap opens Blurt   |
| idle                   | orb still · `TAP OR HOLD TO TALK`              | orb, mic glyph                  |
| connecting             | orb sweeping · `CONNECTING`                    | ring 2 pt sweeping              |
| recording              | orb sweeping · live meter                      | ring sweeping, stop glyph, glow |
| processing             | orb sweeping · `TRANSCRIBING`                  | ring sweeping                   |
| pasted / copied        | `PASTED` / `COPIED` alone                      | orb                             |
| error                  | `ERROR` in orange, alone; message on VoiceOver | orb                             |

The slim bar uses `TAP TO START` / `TAP OR HOLD` (`compact`), since its pill is
a third of the width. One body for every state; cross-fade 0.15 s.

**Orb** (`BrandOrb.swift`) — the gradient disc with a hairline ring that sweeps
one turn per 1.6 s while something is happening, still otherwise. The disc
never moves. Under Reduce Motion the ring is drawn but holds still.

**Meter** (`WaveformMeter` in `StatusPill.swift`) — bars 3 pt wide, 3 pt apart,
count from the width, heights from `MeterBarRow` (envelope, gamma, idle wave).
The app publishes the level at ~12 Hz; the wave keeps the row alive between.

**Mic key** (`MicKey` in `KeyboardViews.swift`) — the orb _is_ the key: 96 pt
in the panel, 44 in the slim bar, 42 in the full keyboard's bottom row. The
Mac's orb carries no glyph; a key needs one, so a white `mic.fill` (0.36 × size)
sits on it, becoming `stop.fill` while recording. Recording adds a green glow
(`greenOnDark` at 35–80 % with the level, radius 0.1–0.35 × size). Ring 2 pt
while working, 1 pt otherwise. Pressed: scale 0.94, 0.1 s. Finger down / up
drive the engine's `DictationKeyGate`, so a tap latches and a hold is
push-to-talk exactly as on the Mac.

**Keys** (`KeyCap`, `LetterKey`) — 42 pt tall, radius 6, 6 % white hairline;
`key` for letters and space, `keyDark` for modifiers; a key brightens 15 %
while pressed rather than dimming.

## Layouts and their heights (`KeyboardLayout.height`)

Top and bottom margin 8 (`KeyboardRootView`); the look sets the row gap and side margin.

| Layout    | Rows                                                                             | Height                |
| --------- | -------------------------------------------------------------------------------- | --------------------- |
| `slimBar` | globe · pill · mic 44 · delete · return                                          | 60                    |
| `panel`   | pill 36 · mic 96 (cancel beside it while in flight) · space row 42, gaps 12      | 216                   |
| `full`    | pill 36 · three letter rows 42 · globe/123/space/mic/return 42; `220 + 4·rowGap` | 252 Blurt, 264 iPhone |

The pill is capped at 260 pt wide in the panel and full layouts, flexible in
the slim bar. The globe key appears only when iOS says another keyboard is
installed (`needsInputModeSwitchKey`).

## Feedback

Haptics (`KeyboardModel.haptics`): medium impact on `recording`, light on the
stop, `.success` on pasted/copied, `.error` on error. The DX7 start/stop cues
play in the app, not the keyboard (a keyboard plays audio only with Full
Access, and the app already owns the audio session).

## Accessibility

The pill is one element carrying the state's label (the Mac's wording where
the states match); the mic key is a button labelled Dictate / Stop dictation /
Start Blurt. Reduce Motion stops the ring and the meter's idle wave; heights
still follow the level.

## The app's screens (`BlurtiOS/Sources/`)

Appearance-adaptive, unlike the keyboard: `accent` (the catalog's
`AccentColor`, `green` in light and `greenOnDark` in dark), `cardFill` /
`cardBorder` (the Mac's card, `#EBE8E8` on `#DEDBDB` light, `#26231E` on
`#3A362F` dark, 16 pt corners, 1 pt hairline), system grouped background,
system fonts. The Mac's Icon Composer icon and its ready-screen wordmark are
shared, not copied (`project.yml`).

**Home** (`HomeView.swift`) — the Mac's ready screen, stacked for a phone:

| Piece      | What                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Bar        | the wordmark (tinted accent, 22 pt tall) centred; the gear → Settings                                                                                                                                                                                                                                                                                                                                                          |
| Setup card | only while something is missing: sign in (stub; debug builds take a key), microphone, keyboard + Full Access                                                                                                                                                                                                                                                                                                                   |
| Hero card  | the orb, 112 pt, ring 2 pt sweeping while the mic is open or a dictation is in flight, glowing with the level while recording; a title2 line (Not listening · Ready to dictate · Listening… · Transcribing… · Pasted · Copied · the error) and a callout under it; the meter while recording; **Start listening** (prominent) or **Stop listening** (bordered, destructive); "Dictate here, to the clipboard" as a text button |
| Style      | chips: Default and each profile, the active one filled with the accent; Edit → the styles editor                                                                                                                                                                                                                                                                                                                               |
| Recent     | cards: three lines of text, the style as a tinted capsule, the relative time, a copy button; an empty-state card                                                                                                                                                                                                                                                                                                               |
| Footer     | "Powered by AssemblyAI", caption                                                                                                                                                                                                                                                                                                                                                                                               |

**Settings** (`SettingsView.swift`) — a sheet, grouped as the Mac's: Keyboard
(layout, look, hands-free), Listening (the window), Transcription (enhanced
transcripts, output styles, key terms with the contact-name count), Account
(sign-in stub; the API key in debug builds), About (version, GitHub, Powered
by AssemblyAI).

Screenshots: `scripts/ios-sim.sh --screenshot home.png` for the resting
screen; `BLURT_LAUNCH_ARGS=-BlurtStartListening` opens the mic at launch for
the listening state (debug builds); `xcrun simctl ui booted appearance dark`
before either for dark mode.

## Next

Onboarding as a stepped flow once sign-in exists; the keyboard's autocorrect
and suggestion bar; the app's cues and haptics on the phase edges.
