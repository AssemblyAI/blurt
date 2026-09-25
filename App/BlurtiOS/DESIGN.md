# Blurt for iPhone — design

The iPhone app and its keyboard are the Mac app's design on a phone: the same
ink, the same two greens, the same orb, the Mac pill's meter and ring. Nothing here was
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

## One look, the iPhone's spacing (`BlurtKeyboard/Sources/KeyboardPalette.swift`)

The keys sit exactly where the iPhone keyboard's do, so nobody's fingers are
thrown off: 6 pt between keys, 11 pt between rows, 3 pt at the edges, 5 pt
corners, a 1 pt drop under every key. The colours are Blurt's — the ink
surface and the tokens below — in every appearance, for the reason the Mac
pill is: the keyboard floats over whichever app the user is typing in.
`KeyboardPalette` is one value for now and the seam themes plug into later.

The full layout follows the iPhone's geometry: ten letter keys across at one
width (`(width − 9·gap) / 10`), the middle row centred, shift and delete
taking what seven letters leave (twice the gap away from them), then 123 ·
globe · space · mic · return, return two modifiers wide. Letters pop up
while pressed (a 32 pt copy 58 pt above the key, typed on release); shift
comes on by itself at the start of a sentence — or of every word, or always
— as the field's `autocapitalizationType` asks, and goes off after one
letter; a second space within 450 ms of the first, after a word, becomes
". ". Not yet: autocorrect and the suggestion bar.

**Later: themes.** Users will pick their own. The iPhone keyboard's own
palettes are the first two to offer, and were measured for it: light —
surface `#D1D5DB`, letter keys white, modifiers `#ADB3BC`, drop `#898A8D`,
black legends; dark — surface `#2B2B2B`, keys `#6B6B6B`, modifiers
`#464646`, drop `#0D0D0D`, white legends; both follow the field's
`keyboardAppearance`, else the app's style.

## Hands-free

On by default, with a toggle in Settings: a dictation starts the moment the
keyboard comes up in a text field — the same synthetic tap through the
engine's gate, so it latches and the next tap of the mic stops it. Only when
the app is listening and nothing is in flight; otherwise the orb sits dimmed
and the first tap opens Blurt. It fires on the keyboard's
appearance, not on every field change while it stays up.

## Tokens (`Shared/BlurtBrand.swift`)

| Token             | Value       | Use                                                         |
| ----------------- | ----------- | ----------------------------------------------------------- |
| `green`           | `#01762F`   | the wordmark green, light chrome (the app's accent)         |
| `greenOnDark`     | `#67AD82`   | the meter, the ring, anything green on ink                  |
| `ink`             | `#1D1B16`   | the Mac pill's body; the keyboard's surface                 |
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

**Voice bar** (`VoiceBar.swift`) — the only place voice lives, and it has no
words and no glyph: the orb is the mic key, 40 pt in a 44 pt row where the
system keyboard puts its suggestion bar. The panel has it at 96 pt, centred
in the space above the keys; the slim bar has it between the globe and
delete. State is the orb's own shape and ring:

| State                              | Orb                                                                                                                                                          | Haptic        |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------- |
| no Full Access / app not listening | dimmed (saturation 0.35, opacity 0.8); a tap opens Blurt                                                                                                     | —             |
| idle                               | the circle, ring still                                                                                                                                       | —             |
| connecting                         | ring 2 pt sweeping, as the app's orb does (one turn per 1.6 s)                                                                                               | —             |
| recording                          | the circle grows sideways into a capsule (200 wide in the bar, 260 in the panel; spring 0.35 s) holding the live wave in white, glowing green with the level | medium impact |
| processing                         | back to the circle, ring sweeping                                                                                                                            | light impact  |
| pasted                             | green solid ring, 1.2 s                                                                                                                                      | success       |
| copied (no field)                  | green solid ring with a clipboard glyph, 2 s                                                                                                                 | success       |
| error                              | orange solid ring with an exclamation mark, 2 s; the message on VoiceOver                                                                                    | error         |

Every transition 0.15 s; the grow and shrink a spring. VoiceOver keeps the
words: Dictate / Stop dictation / Start Blurt on the key, and the error
message.

**Orb** (`BrandOrb.swift`) — the gradient disc with a hairline ring that sweeps
one turn per 1.6 s while something is happening, still otherwise. The disc
never moves. Under Reduce Motion the ring is drawn but holds still.

**Meter** (`WaveformMeter` in `VoiceBar.swift`) — bars 3 pt wide, 3 pt apart,
count from the width, heights from `MeterBarRow` (envelope, gamma, idle wave).
The app publishes the level at ~12 Hz; the wave keeps the row alive between.

**Mic key** (`MicKey` in `KeyboardViews.swift`) — the orb _is_ the key, one
capsule shape whose width is its height until recording. No glyph: the Mac's
orb carries none and neither does this. Recording adds a green glow
(`greenOnDark` at 35–80 % with the level, radius 0.1–0.35 × size). Ring 2 pt
while working or noticing, 1 pt otherwise. Pressed: scale 0.94, 0.1 s.
Finger down / up drive the engine's `DictationKeyGate`, so a tap latches and
a hold is push-to-talk exactly as on the Mac; a touch that travelled more
than 24 pt cancels instead (it was a swipe). Cancel is the orange × in the
panel's top-right corner while something is in flight.

**Keys** (`KeyCap`, `LetterKey`) — 42 pt tall, radius 6, 6 % white hairline;
`key` for letters and space, `keyDark` for modifiers; a key brightens 15 %
while pressed rather than dimming.

## Layouts and their heights (`KeyboardLayout.height`)

Top and bottom margin 8 (`KeyboardRootView`); 11 between rows and 3 at the sides (`KeyboardPalette`).

| Layout    | Rows                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Height                   |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| `slimBar` | globe · voice bar · delete · return                                                                                                                                                                                                                                                                                                                                                                                                                             | 60                       |
| `panel`   | orb 96, centred (cancel in the top-right corner while in flight) · space row 42. A two-page carousel: a horizontal swipe in either direction, as often as you like, flips between the mic panel and the full keyboard; the page slides the way the finger went, the keyboard resizes with it, and it is back to the orb each time the keyboard appears. Keys ignore a touch that travelled more than 12 pt, the orb cancels one that travelled more than 24 pt. | 216, or 272 when flipped |
| `full`    | voice bar 44 · three letter rows 42 · 123/globe/space/return 42; `8·2 + 44 + 4·11 + 4·42`                                                                                                                                                                                                                                                                                                                                                                       | 272                      |

The globe key appears only when iOS says another keyboard is
installed (`needsInputModeSwitchKey`).

## Feedback

Haptics (`KeyboardModel.haptics`): medium impact on `recording`, light on the
stop, `.success` on pasted/copied, `.error` on error — with no words on the
keyboard, they are half of the feedback. The DX7 start/stop cues
play in the app, not the keyboard (a keyboard plays audio only with Full
Access, and the app already owns the audio session).

## Accessibility

The mic key is a button labelled Dictate / Stop dictation / Start Blurt, and
speaks the error message; the meters are hidden from VoiceOver. Reduce
Motion stops the ring and the meter's idle wave; heights still follow the
level.

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
