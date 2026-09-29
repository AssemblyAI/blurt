# Blurt for iPhone — design

The iPhone app and its keyboard are the Mac app's design on a phone: the same
ink, the same two greens, the same orb, the Mac pill's meter and ring. Nothing here was
invented; every number traces to a Mac source file, and where the phone needed
something the Mac has no equivalent for, this file says what was decided and
why.

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
`recording` (level 0.62), `processing`, `pasted`, `copied`, `error`; `landed`
(the drop, timed for a 3 s screenshot); `live` (a whole dictation walked on
a clock, over and over — the way to watch or record the fades); and two
of the keyboard's own: `keys` (the panel flipped to its keyboard page) and
`term` (the key-term field mid-typing, e.g. `-BlurtGallery panel keys,term`). The
gallery is `BlurtiOS/Sources/KeyboardGalleryView.swift`, debug builds only;
the keyboard's sources are compiled into the app for it (`project.yml`).

## Prototype on this branch: the prism orb (`PrismOrb.swift`)

The brand artwork — a green beam into the prism, a violet, starlit one out —
as the orb's own story. The mic key and the home hero are filled by a 3 × 3
`MeshGradient` whose edge and centre points drift on slow sines (further
with the voice level), under a soft upper-left light and animated film grain
(a seeded scatter of faint dots, new each frame at 20 Hz). The orb lives
**green**: calm at rest (`idle`, `working`, `off`), greener and brighter with
the voice (`listening(level:)`). The moment the words land in the field —
`resultLandedAt` on the keyboard, the phase reaching pasted or copied on the
home screen — a **violet drop** falls in: a bloom that grows from the centre
(the mesh soaks violet centre-first, corners least), six four-point sparkles
bursting a beat apart, up in 0.5 s, held to 0.9 s, flowing back out into the
green by 2.4 s. It lands with the success haptic. Under Reduce Motion the
fluid holds still and the drop simply fades. The ring stays the Mac orb's.

The orb is a circle, never a pill, and while you talk it is not there at
all: it **dissipates** — swells a little, softens to a haze, is gone
(`Dissipate`) — and in its place the voice is a **thin wave** (`WaveformMeter`
at the keyboard's pitch: 2 pt bars 2 pt apart, dense, slim, flat on the
surface with no container). The wave is the key while it shows; on the stop
it fades and the orb condenses back the same way. Motion is soft and slow:
the crossing takes 0.7 s, every other change on the key 0.5 s, nothing
springs or snaps; only the press answers at once.

The chrome is flat and contemporary: one colour per key at 8 pt corners, no
drop, no edge, no gloss; the +, the cancel ×, the term field's × and ✓ are
bare glyphs; the term field a flat capsule; the letter pop-up carries only a
whisper of shadow (12 %, radius 8), being the one thing that floats.

Not merged: judge it on the simulator (`-BlurtGallery panel
idle,recording,landed`; `-BlurtGallery panel live` walks a whole dictation
on a clock, for watching or `xcrun simctl io booted recordVideo`;
`-BlurtStartListening` for the hero).

## Themes, at the iPhone's spacing (`BlurtKeyboard/Sources/KeyboardPalette.swift`)

The keys sit exactly where the iPhone keyboard's do, so nobody's fingers are
thrown off: 6 pt between keys, 11 pt between rows, 3 pt at the edges. The
keys are flat — one colour at 8 pt corners, no drop, no edge. A theme changes
how the keyboard looks and never how it types. The **default is the iPhone keyboard's own** look,
light or dark with the app being typed in (its field's `keyboardAppearance`,
else the app's style), so Blurt's keys sit on Apple's globe-and-mic bar as
one keyboard and the brand lives in the orb. Six more, curated,
Partiful-style — pick from live previews in Settings → Keyboard → Theme; the
keyboard picks it up the next time it comes up (`keyboardTheme` in the App
Group):

| Theme      | Surface               | Key               | Modifier              | Legend        | Vibe                                        |
| ---------- | --------------------- | ----------------- | --------------------- | ------------- | ------------------------------------------- |
| `system`   | `#D1D5DB` / `#2B2B2B` | white / `#6B6B6B` | `#ADB3BC` / `#464646` | black / white | the iPhone keyboard, light / dark (default) |
| `ink`      | `#1D1B16`             | `#33302A`         | `#26231E`             | `#F2EEE6`     | Blurt's own                                 |
| `paper`    | `#EBE8E8`             | white             | `#DEDBDB`             | `#1D1B16`     | warm and light                              |
| `lavender` | `#2C2557`             | `#3F3777`         | `#352E68`             | `#F1EEFF`     | the orb's violet                            |
| `mint`     | `#10231B`             | `#1E3F31`         | `#183429`             | `#E9F5EE`     | the orb's green                             |
| `midnight` | `#0E1220`             | `#1D2440`         | `#161B33`             | `#E8ECFF`     | deep blue-black                             |
| `sunset`   | `#2B1912`             | `#4B2B20`         | `#3B2119`             | `#FFEFE6`     | warm and loud                               |

The orb and the ring are the same in every theme; the wave takes the
palette's `signal` green — the wordmark's on the light surfaces, the lifted
one on the dark. The picker (`ThemePickerView`) draws the real full keyboard at 0.42 scale on
each card, the iPhone theme in the picker's own appearance. The gallery's
last argument is a theme id (`system-dark` for the iPhone's dark face).

The full layout follows the iPhone's geometry: ten letter keys across at one
width (`(width − 9·gap) / 10`), the middle row centred, shift and delete
taking what seven letters leave (twice the gap away from them), then 123 ·
globe · space · return, return two modifiers wide. Letters pop up while
pressed (a 32 pt copy 58 pt above the key, typed on release); shift comes on
by itself at the start of a sentence — or of every word, or always — as the
field's `autocapitalizationType` asks, and goes off after one letter; a
second space within 450 ms of the first, after a word, becomes ". ". Not
yet: autocorrect and the suggestion bar.

## Quick-add key term

The most-asked-for thing: Blurt mishears a niche word, and the fix has to take
seconds, inside the app you're typing in, never a trip to Settings.

1. Select the misheard word in your text (or select nothing).
2. Tap the small **+** beside the orb (top-right of the bar; top-left corner of
   the panel). The bar becomes a field — × · what you type · ✓ — pre-filled
   with the selection, and the keys type into it (the panel and slim bar flip
   to the letter keys for it). Shift is on for the first letter.
3. Type the right spelling; return or ✓ saves. The term goes into Blurt's key
   terms (`BlurtKeyTerms` in the App Group, `KeyTermList` rules: trimmed,
   deduplicated case-insensitively) and rides `keyterms_prompt` on the very
   next dictation. If it began as a selection and you changed it, the
   misheard word in your text is replaced with what you typed. A success
   haptic, and the + shows a check for 1.2 s.

× or an empty save leaves the mode, and so does the keyboard going away. A
hardware keyboard (an iPad's, a Bluetooth one, the simulator's Mac) types
past the on-screen keys into the app's field; while the term field is open a
short run that appears there right after where the cursor was — the text
before the cursor grew, the text after it didn't, nothing is selected — is
moved into the term and taken back out of the field; a cursor move changes
both sides and is left alone. A selection that carried spaces around the
word keeps them on replacement. The list itself is edited in Settings →
Transcription, which shows the count against the request's cap of 100 terms
(`KeytermsBoost`); the engine applies the caps on the request, first terms
first.

## Sharing key terms

A group chat has names and slang everyone's dictation should get right, so a
list travels. Settings → Transcription → **Share key terms…** puts the list
in the share sheet as a `.blurtterms` file (JSON — `name`, `from`, `terms`; a
declared document type, `dev.alex.blurt.terms`) with the words as the
message text, so a friend without Blurt still gets them. A tap on the file
in Messages opens Blurt with "Add N key terms?": every term ticked, untick
any, Add merges the rest without duplicates. A `blurt://terms?add=a,b,c&name=…&from=…`
link does the same (`TermPack`, `ImportTermsView`). A pack is refused over
64 KB, past 100 terms (the request's own cap; the rest are dropped) or with a
term, name or sender over 80 characters; a file or link that claims to be a
pack and isn't gets "Couldn't read that list". A file iOS handed over in the
app's Inbox is deleted once read.

## Adapting to the phone's own keyboard settings

Nothing to configure: key clicks play only if the user has keyboard clicks
on (the input view adopts `UIInputViewAudioFeedback`; `playInputClick` on
letters, space, delete and return); the return key says what the field asks — send, search, go, done,
next, join — with the glyph otherwise; a number, decimal or phone field opens
on the symbols page; capitalisation follows the field's
`autocapitalizationType`; the letter rows follow the phone's first language
(AZERTY for French, QWERTZ for German, Czech, Slovak and Hungarian, QWERTY
otherwise).

## Hands-free

On by default, with a toggle in Settings: a dictation starts the moment the
keyboard comes up in a text field — the same synthetic tap through the
engine's gate, so it latches and the next tap of the mic stops it. Only when
the app is listening and nothing is in flight; otherwise the orb sits dimmed
and the first tap opens Blurt. It fires on the keyboard's appearance, not on
every field change while it stays up. When the keyboard leaves the screen
with a dictation it started, it releases a recording (the words still land,
on the clipboard if no keyboard is there) and cancels anything earlier, so
nothing records on without it.

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

The default theme follows the host app's light or dark appearance, as the
iPhone keyboard does; Blurt's own themes are **fixed**, whatever the host
app's appearance, for the reason the Mac pill is: the keyboard floats over
whichever app the user is typing in and must read the same over a white Notes
page and a black Messages thread. Nothing on it uses `accent`.

## Type

Key legends: letters 22 pt regular,
everything else 16 pt medium. System font throughout.

## Components (`BlurtKeyboard/Sources/`)

**Voice bar** (`VoiceBar.swift`) — the only place voice lives, and it has no
words and no glyph: the orb is the mic key, 40 pt in a 44 pt row where the
system keyboard puts its suggestion bar. The panel has it at 96 pt, centred
in the space above the keys; the slim bar has it between the globe and
delete. State is the orb's ring and colour, and the wave:

| State                              | Orb                                                                                                                                                       | Haptic        |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- |
| no Full Access / app not listening | dimmed (saturation 0.35, opacity 0.8); a tap opens Blurt                                                                                                  | —             |
| idle                               | the circle, ring still                                                                                                                                    | —             |
| connecting                         | ring 2 pt sweeping, as the app's orb does (one turn per 1.6 s)                                                                                            | —             |
| recording                          | the orb dissipates (swells, blurs, fades; 0.7 s) into the thin wave, flat on the surface: 240 × 24 in the bar, 300 × 40 in the panel; the wave is the key | medium impact |
| processing                         | back to the circle, ring sweeping                                                                                                                         | light impact  |
| pasted                             | green solid ring, 1.2 s                                                                                                                                   | success       |
| copied (no field)                  | green solid ring with a clipboard glyph, 2 s                                                                                                              | success       |
| error                              | orange solid ring with an exclamation mark, 2 s; the message on VoiceOver                                                                                 | error         |

Nothing snaps: the orb and the wave cross over 0.7 s, every other change on
the key (ring, glyph, dimming) over 0.5 s, and the term field swaps in over
0.4 s. Only the press answers at once. VoiceOver keeps the words: Dictate / Stop
dictation / Start Blurt on the key, and the error message.

**Orb** (`BrandOrb.swift`) — the gradient disc with a hairline ring that sweeps
one turn per 1.6 s while something is happening, still otherwise. The disc
never moves. Under Reduce Motion the ring is drawn but holds still.

**Meter** (`WaveformMeter` in `VoiceBar.swift`) — the Mac pill's bars, at
the pitch the caller sets: the keyboard and the home screen use `slimBar` /
`slimGap` (2 pt bars, 2 pt apart), the count from the width, heights from
`MeterBarRow(count:availableHeight:)` (the engine's envelope, gamma and idle
wave, so it cannot drift from the Mac's). The app publishes the level at
~12 Hz; the wave keeps the row alive between. The colour is the palette's
`signal` on the keyboard and `accent` on the home screen.

**Mic key** (`MicKey` in `KeyboardViews.swift`) — the orb _is_ the key until
it dissipates into the wave, and then the wave is (`wave: CGSize?`; nil in
the Full Access row, where the orb stays). The key's frame is the wave's
width throughout so nothing shifts while the two cross; the touch shape is
the circle, then the wave's band. No glyph: the Mac's orb carries none and
neither does this. No glow, no shadow — matte. Ring 2 pt while working or
noticing, 1 pt otherwise. Pressed: scale 0.94, 0.1 s.
Finger down / up drive the engine's `DictationKeyGate`, so a tap latches and
a hold is push-to-talk exactly as on the Mac; a touch that travelled more
than 24 pt cancels instead (it was a swipe). Cancel is the orange × in the
panel's top-right corner while something is in flight.

**Keys** (`KeyCap`, `LetterKey`) — 42 pt tall, radius 8, flat: `key` for
letters and space, `keyDark` for modifiers, `bare` for a glyph with no cap
(the panel's cancel); a key brightens 15 % while pressed rather than dimming.

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

## The two processes, and every number

The app listens and transcribes; the keyboard is a remote control. They talk
over the App Group's `UserDefaults` (payloads as JSON) plus Darwin
notifications that carry nothing and just say "look" (`SharedState.swift`).

| Rule                   | Value                                                                                                           | Why                                                                                                      |
| ---------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| presence               | heartbeat 5 s (app), 4 s (keyboard); window 15 s                                                                | more than twice a heartbeat, so one missed beat isn't absence; a killed process is absent within seconds |
| listening              | window not lapsed **and** app seen within 15 s                                                                  | a killed app, or a phone call, with the window's end still in the future                                 |
| result freshness       | 10 s                                                                                                            | a notification held for a suspended keyboard arrives minutes late                                        |
| result addressing      | `recipient` = the keyboard instance last seen                                                                   | two live keyboards (two host apps) must not both insert                                                  |
| result delivery        | the app waits 3 s (poll 250 ms) for the keyboard to take the result; else clipboard + "Copied"                  | "Pasted" is never a guess                                                                                |
| command freshness      | 10 s                                                                                                            | a held press from minutes ago must not start a dictation on resume                                       |
| command retry          | one re-signal after 600 ms with no phase change                                                                 | a missed Darwin notification would leave the gate latched over nothing                                   |
| phase staleness        | notices 3 s (max dwell 2 s + 1); in flight 130 s (the 120 s cap + 10)                                           | the keyboard reads the snapshot on every appearance                                                      |
| notice dwell           | pasted 1.2 s; copied, error 2 s                                                                                 | the Mac's 0.8 / 1.6 s, a little longer with no hover                                                     |
| press delay on the orb | 90 ms                                                                                                           | a swipe that starts on the orb never starts a dictation it must then cancel                              |
| tap travel             | 12 pt (keys), 24 pt (orb), swipe ≥ 48 pt horizontal and 1.5× the vertical                                       | the carousel's swipe never types or dictates                                                             |
| level publish          | every 80 ms while recording                                                                                     | the orb's meter, off the capture path's back                                                             |
| lexicon refresh        | hourly                                                                                                          | thousands of contacts on a keyboard memory budget                                                        |
| height change          | 0.25 s; constraint priority 999                                                                                 | iOS honours a keyboard's height at just under required                                                   |
| wave                   | 2 pt bars 2 pt apart; 240 × 24 (bar), 300 × 40 (panel), 280 × 44 (home)                                         | thin, dense, slim; one component for the keyboard and the home screen                                    |
| dissipate              | scale to 1.25, blur 0.16 × the orb, opacity to 0, over the 0.7 s crossing                                       | mist, not a pop; the same in reverse                                                                     |
| fades                  | orb ↔ wave 0.7 s; ring, glyph, dimming 0.5 s; term field 0.4 s; the drop up 0.5 s, held to 0.9 s, gone by 2.4 s | soft and slow; only the press (0.1 s) answers at once                                                    |
| keys                   | radius 8, no drop, no edge; pop-up radius 10 with a 12 % shadow at radius 8                                     | flat and contemporary; the pop-up is the one thing that floats                                           |
| letter pop-up          | 32 pt glyph, key width + 18 × 56, radius 10, 58 pt above                                                        | the system keyboard's geometry                                                                           |
| term field             | 36 pt, 17 pt text, caret 0.5 s; the + is 32 pt                                                                  | —                                                                                                        |
| term packs             | ≤ 64 KB, ≤ 100 terms, ≤ 80 characters each                                                                      | the request's cap; unbounded input from a stranger                                                       |

Tests pin the rules that can be pinned (`BlurtiOSTests`: the contract, the
gate, results, the term field, the feed, the layout arithmetic); anything
that gains a number here should gain a line there.

## The app's screens (`BlurtiOS/Sources/`)

Appearance-adaptive, unlike the keyboard: `accent` (the catalog's
`AccentColor`, `green` in light and `greenOnDark` in dark), `cardFill` /
`cardBorder` (the Mac's card, `#EBE8E8` on `#DEDBDB` light, `#26231E` on
`#3A362F` dark, 16 pt corners, 1 pt hairline), system grouped background,
system fonts. The Mac's Icon Composer icon and its ready-screen wordmark are
shared, not copied (`project.yml`).

**Home** (`HomeView.swift`) — the Mac's ready screen, stacked for a phone:

| Piece      | What                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bar        | the wordmark (tinted accent, 22 pt tall) centred; the gear → Settings                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Setup card | only while something is missing: sign in (stub; debug builds take a key), microphone, keyboard + Full Access                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Hero card  | the orb, 112 pt, ring 2 pt sweeping while the mic is open or a dictation is in flight, dissipating into the thin wave (280 × 44) while recording as the keyboard's key does; a title2 line (Not listening · Ready to dictate · Connecting… · Listening… · Transcribing… · Pasted · Copied · the error) and a callout under it; **Start listening** (prominent; refused without a key, with a line saying so) or **Stop listening** (bordered, destructive; cancels a dictation in flight before closing, so nothing is transcribed for nobody); "Dictate here, to the clipboard" as a text button |
| Style      | chips: Default and each profile, the active one filled with the accent; Edit → the styles editor                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Recent     | cards: three lines of text, the style as a tinted capsule, the relative time, a copy button; an empty-state card                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Footer     | "Powered by AssemblyAI", caption                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |

**Settings** (`SettingsView.swift`) — a sheet, grouped as the Mac's: Keyboard
(layout, theme, hands-free), Listening (the window), Transcription (enhanced
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
