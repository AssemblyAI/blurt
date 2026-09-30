# Blurt for iPhone — design

The iPhone app and its keyboard are Blurt's brand on a phone: Cam Neri's
"warped futurism" as it appears on assemblyai.com/blurt — an ink ground
under film grain, a warm paper one in the light, serif headlines, uppercase
mono labels, green as the one signal, rectangular corners — at the iPhone
keyboard's own measured geometry, so nothing is unfamiliar under the fingers.
Nothing here is decoration: every number and colour is a token, every rule
has a test, and every state can be captured from a launch argument.

Sources of truth: the brand design system
(`https://www.assemblyai.com/brand-design-system/assemblyai-brand-design-system.md`)
and the Blurt landing page for the look; `Design/apple-geometry.json` for the
keys; `Design/tokens.json` for every value the views draw with. From the
tokens, `scripts/design-tokens.swift` writes `Shared/DesignTokens.swift`
(what the views read), the tables in this file marked `tokens:begin` /
`tokens:end`, the app's asset-catalog colour sets, and the Figma build's
variables. Edit the JSON, run `scripts/design-sync.sh`, commit; `check.sh`
runs `design-sync.sh --check` and fails on drift or on a design literal in a
view (`// literal-ok: <reason>` for a genuine derivation).

## Reproducing it

Every layout and state renders inside the app, from a launch argument, so a
screenshot never depends on tapping through Notes:

```bash
BLURT_LAUNCH_ARGS="-BlurtGallery panel idle,recording,processing dark" scripts/ios-sim.sh --screenshot panel.png
BLURT_LAUNCH_ARGS="-BlurtGallery full idle,symbols,send light" scripts/ios-sim.sh --screenshot full.png
BLURT_LAUNCH_ARGS="-BlurtSettings" scripts/ios-sim.sh --screenshot settings.png
```

Layouts: `slimBar`, `panel`, `full`. Faces: `light`, `dark` (the older theme
words still land on one). States: `off` (no Full Access), `start` (the app
isn't listening), the pipeline's `idle`, `connecting`, `recording` (level
0.62), `processing`, `pasted`, `copied`, `error`; `landed` (the glint, timed
for a 3 s screenshot); `live` (a whole dictation walked on a clock, over and
over, for watching or recording); and the keyboard's own `keys` (the panel
flipped to its keyboard page), `symbols`, `term` (the key-term field
mid-typing), `send` (a return key with a label), `saved` (the + just after a
term was saved). `-BlurtGalleryVoice a|b|c` picks the mic concept
(below). The gallery is `BlurtiOS/Sources/KeyboardGalleryView.swift`, debug
builds only; the keyboard's sources are compiled into the app for it.

For the design loop a capture has to be the same pixels every time, and it
has to be the keyboard's pixels alone: `-BlurtGalleryStill` holds every
motion at time zero (what Reduce Motion does) and `-BlurtGalleryBare` draws
the first row by itself inside a 2 pt `#FF00FF` registration border.
`-BlurtVoice <a|b|c> <bar|panel|home> <state> [light|dark]` renders one voice
element the same way. The scripts on top:

```bash
scripts/design-capture.sh --layout panel --states idle,recording,error,term --themes light,dark [--voice a]
    # builds once, captures each still, crops it → .build/design/captures/<layout>-<state>-<face>[-<voice>]@3x.png
scripts/ios-record.sh --layout panel --theme dark [--voice a]
    # one 11.7 s loop of the `live` walk, cropped
swift scripts/design-diff.swift diff a.png b.png --out triptych.png --json metrics.json
    # sRGB, AE and RMSE; `sheet` makes a contact sheet; `measure` reads a keyboard's caps off a screenshot
scripts/apple-geometry.sh          # measures the iPhone's own keyboard → Design/apple-geometry.json
scripts/ios-keyboard-shot.sh --face dark --voice b --layout panel
    # the real keyboard — the extension in its own process — over a field in the app: what the gallery
    # cannot vouch for (a canvas that renders asynchronously never presents in an extension)
scripts/design-sync.sh [--check]   # tokens.json → DesignTokens.swift, these tables, the colour sets
```

The capture device is the iPhone 18 Pro (402 pt → 1206 px at 3×), pinned in
`scripts/ios-sim.sh`; a crop that is not the layout's height fails rather
than being resampled.

## The two faces

The keyboard follows the field it is typing into, as the iPhone's does:
**dark** — ink under the brand's film grain, the website's ground — when the
host field's `keyboardAppearance` is dark, else the app's own appearance;
**light** — warm paper — otherwise. Both are the brand; neither is Apple's
grey. A face changes how the keyboard looks and never how it types. The
curated themes come back later as value sets through the same
`KeyboardPalette` shape (`all`, `resolve(_:dark:)`); a retired id resolves to
the brand's face. Ten roles each (`BlurtKeyboard/Sources/KeyboardPalette.swift`):

<!-- tokens:begin themes -->

| Face    | Surface   | Key       | Modifier  | Legend    | Secondary | Signal    | Pop-up    | Field     | Field border | Notice    | Key in container | Modifier in container | Host material |
| ------- | --------- | --------- | --------- | --------- | --------- | --------- | --------- | --------- | ------------ | --------- | ---------------- | --------------------- | ------------- |
| `light` | `#ECEBE5` | `#FFFFFF` | `#DAD7CB` | `#1D1B16` | `#777673` | `#01762F` | `#FFFFFF` | `#FFFFFF` | `#C7C3B2`    | `#E67F36` | `#FFFFFF`        | `#DAD7CB`             | `#E2E3E8`     |
| `dark`  | `#1D1B16` | `#33302A` | `#26231E` | `#F5F3EB` | `#A5A4A2` | `#67AD82` | `#33302A` | `#33302A` | `#3A362F`    | `#E67F36` | `#575757`        | `#474747`             | `#373737`     |

<!-- tokens:end themes -->

**The surface is the host's.** iOS 26 wraps a third-party keyboard in the host
app's own rounded keyboard material, inset above and below by about 16 pt,
and nothing the keyboard draws reaches the inset (Apple: working as
intended). A painted surface therefore shows a band of the host's grey above
it, in every Liquid Glass app. So the surface is **clear** by default
(`surface/paint` 0): the host's material is the surface, seamlessly, and the
keys take the face's `container-key` / `container-key-modifier` colours,
which read on the system's light and dark material (measured from the iPhone
keyboard: `#575757` keys on the dark one). The brand lives in the keys, the
labels and the voice element. `surface/paint` 1 paints the face's surface
and grain under the keys — and accepts the band. The keyboard's height is a
constraint at required − 1, activated from `updateViewConstraints` once the
view has appeared; activated earlier it fights the host's first layout.
`scripts/ios-keyboard-shot.sh` and the `MessagesKeyboardShot` UI test
capture the real keyboard in the app and in Messages.

The app's screens follow the phone's appearance through the asset catalog's
colour sets (generated from the `keyboard.app/*` tokens): `Page`, `Text`,
`Muted`, `CardFill`, `CardBorder`, `AccentColor`, `CTA`, `CTAText`.

## Apple's geometry, measured

The key tokens were assumed until 2026-09-29; now they are measured.
`scripts/apple-geometry.sh` runs the `BlurtiOSProbe` UI test (XCTest, the one
allowed use of it; its own scheme, never in the app's test run or the
periphery scan): the app launches on `-BlurtProbeField light|dark`, a bare
text field takes the system keyboard, the test reads every key's frame and
screenshots both faces. XCUITest reports touch cells, which tile a row with
no gaps, so `design-diff.swift measure` reads the caps themselves — widths,
gaps, height, the corner radius fitted to the top-left inset — off the
screenshot. The result is `Design/apple-geometry.json`; `AppleGeometryTests`
ties the tokens to it, `DesignTokensTests` the geometry to the tokens.

iPhone 18 Pro, iOS 27, 402 pt: caps 33.5 wide and 43 tall, 6 between, 6.5 at
the sides, 11 between rows, corners at 8; shift and delete 45.58 with a 13.67
gap to the letters; 123 and the globe 43.33, return two of those and a gap
(92.67); a 52 pt band above the keys (the suggestion bar's — where the voice
row goes: 8 + 44) and 13 under them; 270 in all. The dark face is identical.
The letter legend estimates at 24 pt from the l glyph. `KeyGeometry`
(`BlurtKeyboard/Sources/KeyGeometry.swift`) is the arithmetic between the
tokens: ten letters and nine gaps across the row, the side keys taking what
seven letters and the side gaps leave, the bottom row's widths scaling from
the reference width; the full keyboard draws from it and carries no
arithmetic of its own. iOS draws its own globe-and-mic bar under a custom
keyboard on a Face ID phone (58 pt), so the globe appears in ours only when
`needsInputModeSwitchKey` says so.

## Keys

Flat, one colour, at the iPhone's corner (8); no edge, no drop, no gloss. A
key brightens 15 % while pressed (0.08 s) rather than dimming; the letter
pop-up carries the one shadow on the keyboard, a whisper (12 %, radius 8),
being the one thing that floats.

Type: the letters are SF Pro at the iPhone's size, and the glyph keys — shift,
delete, globe, the +, × and ✓ — SF Symbols, so the keyboard feels native
under the fingers. Every **word** on a key — `123`, `ABC`, `#+=`, `space`,
`return` and the field's own `send` / `go` / `done` / `search` / `next` / `join` —
is the brand's eyebrow: Modern Gothic Mono, medium, 12 pt, uppercase, +1.2
tracking, in the face's secondary legend, a step quieter than a letter. Fixed
point sizes throughout, as the system keyboard's; no Dynamic Type.

<!-- tokens:begin type -->

| Token                | Value      | Swift                         | Use                                                                               |
| -------------------- | ---------- | ----------------------------- | --------------------------------------------------------------------------------- |
| `ratio/voice-glyph`  | `0.34`     | `Typography.ratioVoiceGlyph`  | the clipboard and exclamation glyphs, as a fraction of the voice element's height |
| `size/body`          | `16`       | `Typography.sizeBody`         | the app's body text                                                               |
| `size/caption`       | `14`       | `Typography.sizeCaption`      | the app's small text                                                              |
| `size/cta`           | `14`       | `Typography.sizeCta`          | a mono button label in the app (E2)                                               |
| `size/eyebrow`       | `12`       | `Typography.sizeEyebrow`      | a mono eyebrow in the app (E1)                                                    |
| `size/glyph`         | `17`       | `Typography.sizeGlyph`        | the +, × and ✓                                                                    |
| `size/label`         | `12`       | `Typography.sizeLabel`        | the mono word labels on keys: 123, ABC, #+=, space, the return label              |
| `size/legend`        | `16`       | `Typography.sizeLegend`       | every other key                                                                   |
| `size/letter`        | `24`       | `Typography.sizeLetter`       | letter keys: the iPhone's (estimated from the l glyph, apple-geometry.json)       |
| `size/popup`         | `32`       | `Typography.sizePopup`        | the letter pop-up                                                                 |
| `size/term`          | `17`       | `Typography.sizeTerm`         | the key-term field                                                                |
| `size/title`         | `34`       | `Typography.sizeTitle`        | the app's serif headline                                                          |
| `tracking/cta`       | `1.4`      | `Typography.trackingCta`      | uppercase mono at 14: the brand's E2 tracking                                     |
| `tracking/eyebrow`   | `1.2`      | `Typography.trackingEyebrow`  | uppercase mono at 12: the brand's E1 tracking                                     |
| `weight/glyph`       | `medium`   | `Typography.weightGlyph`      | —                                                                                 |
| `weight/label`       | `medium`   | `Typography.weightLabel`      | —                                                                                 |
| `weight/legend`      | `medium`   | `Typography.weightLegend`     | —                                                                                 |
| `weight/letter`      | `regular`  | `Typography.weightLetter`     | —                                                                                 |
| `weight/popup`       | `regular`  | `Typography.weightPopup`      | —                                                                                 |
| `weight/term`        | `regular`  | `Typography.weightTerm`       | —                                                                                 |
| `weight/voice-glyph` | `semibold` | `Typography.weightVoiceGlyph` | —                                                                                 |

<!-- tokens:end type -->

The three faces are bundled in both targets (`Design/fonts/`, registered
through `UIAppFonts` in `project.yml`; an extension cannot read the app's
bundle) and reached only through `BlurtType`, by PostScript name:

<!-- tokens:begin fonts -->

| Token             | Value                      | Swift                  | Use                                             |
| ----------------- | -------------------------- | ---------------------- | ----------------------------------------------- |
| `body/bold`       | `UN-11ST-Bold`             | `Fonts.bodyBold`       | —                                               |
| `body/family`     | `UN-11 ST`                 | `Fonts.bodyFamily`     | the app's body text                             |
| `body/regular`    | `UN-11ST-Regular`          | `Fonts.bodyRegular`    | —                                               |
| `heading/family`  | `Oceanic Text`             | `Fonts.headingFamily`  | the app's serif headlines, sentence case, tight |
| `heading/regular` | `OceanicText-Regular`      | `Fonts.headingRegular` | —                                               |
| `mono/family`     | `Modern Gothic Mono`       | `Fonts.monoFamily`     | eyebrows, CTAs, the keyboard's word labels      |
| `mono/light`      | `ModernGothicMono-Light`   | `Fonts.monoLight`      | —                                               |
| `mono/medium`     | `ModernGothicMono-Medium`  | `Fonts.monoMedium`     | —                                               |
| `mono/regular`    | `ModernGothicMono-Regular` | `Fonts.monoRegular`    | —                                               |

<!-- tokens:end fonts -->

`Font.custom` falls back to the system font in silence when a name is wrong,
so the root asserts in debug builds that the bundle knows every face, and
`BlurtTypeTests` pins it. The fonts come from the website's rebrand set; the
licence covers the web, and embedding them in an app that will one day merge
into the public MIT repo is to be settled with Brand Studio first.

## The voice element

The mic control is the one part of the keyboard that says what is
happening, and it says it without a word: the orb is gone. Three concepts
are built side by side behind one seam, `VoiceElementView`
(`BlurtKeyboard/Sources/VoiceElement.swift`), so they can be judged on sight
from the same states, the same level and the same landing moment; the one
that ships stays and the others go. Every candidate draws from
`VoiceElementInputs` — the `VoiceState`, the level inside it, when the words
landed, whether motion is allowed, the face, the slot (bar, panel, home) —
and nothing else. `VoiceClock` holds the clocks they share: the landing
glint (0 → 1 over `motion.landing`), the sheen (one pass per `motion.sheen`
at rest, per `sheen-working` while something is happening), and a facet hash
that makes the glints random to the eye and the same in every capture.

| Kind                           | At rest                                                                                        | Recording                                                                                                                                       | Working                                              | Landed                                                                    | Error                                           |
| ------------------------------ | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------- |
| **a — Grille** (`VoiceGrille`) | a dot lattice (2 pt dots, 4 pt pitch) in a 4 pt-corner rectangle, a diagonal sheen crossing it | the lattice is the meter: columns light bottom-up in green with the engine's envelope, quantised to whole dots; facets on the peaks flash white | one lit dot runs the perimeter on the ring's cadence | a thin white cross glint with a faint prismatic fringe sweeps across once | the lattice orange, an exclamation mark over it |
| **b — Ribs** (`VoiceRibs`)     | a short block of the wave's own bars under a cosine envelope, the sheen passing rib to rib     | the ribs are the wave: they widen to the box and follow the voice                                                                               | the ribs breathe with the sheen                      | a white glint runs the ribs                                               | the ribs orange                                 |
| **c — Streak** (`VoiceStreak`) | a hairline the width of the box with a bright point at its centre                              | the point blooms into a light streak whose reach follows the level, green along it, white at the heart, violet at the tips                      | a short streak sweeps the line back and forth        | the cross's vertical arm flashes through the point                        | the line orange                                 |

**Temporary, while one is chosen:** Settings → Keyboard → Mic switches the
concept in use (`SharedStore.voiceElementKind`, read by the keyboard on every
appearance and by the home screen live). The switch, the two losers and
`-BlurtGalleryVoice` go together once the direction is picked.

What is common: the box (`voice/*`), dimming to `opacity/off` when Blurt
isn't ready (a tap opens the app), the two glyphs that need saying (a
clipboard when the words went there, an exclamation mark on a failure) drawn
by `MicControl` over the element, every change fading over `state-fade`, and
the press answering at once. Under Reduce Motion the sheen and the glints
hold still; the level still drives the meter. The home screen draws the same
element at home size in the app's face.

| State                   | Element                                                                | Haptic                       |
| ----------------------- | ---------------------------------------------------------------------- | ---------------------------- |
| no Full Access          | the note "Allow Full Access in Settings" is the key; a tap opens Blurt | —                            |
| app not listening       | the element at `opacity/off`; a tap opens Blurt                        | —                            |
| idle                    | at rest, the sheen                                                     | —                            |
| connecting / processing | working                                                                | — / light impact on the stop |
| recording               | the meter                                                              | medium impact                |
| pasted                  | the landing glint, the element in green for 1.2 s                      | success                      |
| copied                  | the same, with the clipboard glyph, 2 s                                | success                      |
| error                   | orange, the exclamation mark, 2 s; the message on VoiceOver            | error                        |

The gesture is `MicPressSequencer` (`KeyboardInteraction.swift`), tested: a
press waits 90 ms so a swipe that starts on the key never starts a dictation
it must then cancel; a tap quicker than that is still a tap; a swipe past
24 pt cancels the timer, or undoes a press that went out. Finger down and up
drive the engine's `DictationKeyGate`, so a tap latches and a hold is
push-to-talk exactly as on the Mac.

## Layouts and their heights (`KeyboardLayout.height`)

Side margins 6.5; top 8; under a row of keys 13 (the iPhone's), under the
slim bar 8.

| Layout    | Rows                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Height                   |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| `slimBar` | globe · voice bar · delete · return                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | 60                       |
| `panel`   | the voice element, centred (the + top-left; cancel top-right while in flight) · globe · space · delete · return. A two-page carousel: a horizontal swipe flips between the panel and the full keyboard, and it is back to the element each time the keyboard appears. The pages are a strip one page wide (`PanelCarousel`): the other page is set down a page away on the side the finger moved towards and the strip slides, so the two never cross whichever way the flips come; a flip back mid-slide retreats (`PanelCarouselState`, tested). | 216, or 270 when flipped |
| `full`    | voice row 44, then the first key row right under it as the iPhone's sits under its suggestions · three letter rows 43 · 123 / globe / space / return                                                                                                                                                                                                                                                                                                                                                                                               | 270                      |

The voice row (`VoiceBar`) is where the system keyboard puts its suggestion
bar: the element with the + a clearance beside it, the pair centred on what
the element _shows_ (`VoiceElementKind.visibleWidth`, tested: the grille's
own width, the ribs asleep or the wave awake, the streak's line — never the
slot's box, which would put the + off at the edge; the mic key is never
narrower than a key), or the key-term field. A swipe flips the panel past
48 pt sideways and more sideways than up or down by 1.5×; a key acts on
release and only under 12 pt of travel (`KeyboardInteraction`, tested). The
swipe is recognised on the input view itself (`KeyboardViewController`), not
in SwiftUI, and the keyboard paints a floor under everything at 1 % of the
host material's own colour (`material/*`, so nothing shows; 1 % black read as
a shade darker than the border around it):
the host hands a keyboard only the touches that land on pixels it drew, so
with the surface clear a swipe that started on the panel's empty space never
reached the keyboard at all (`scripts/ios-keyboard-flows.sh` swipes from the
gap, the mic, the space key and the letters, both ways).

## Quick-add key term

The most-asked-for thing: Blurt mishears a niche word, and the fix has to take
seconds, inside the app you're typing in, never a trip to Settings.

1. Select the misheard word in your text (or select nothing).
2. Tap the small **+** beside the element (trailing edge of the bar; top-left
   corner of the panel). The bar becomes a field — × · what you type · ✓ — the
   brand's input, a rectangle at 8 pt with a hairline — pre-filled with the
   selection, and the keys type into it (the panel and slim bar flip to the
   letter keys for it). Shift is on for the first letter.
3. Type the right spelling; return or ✓ saves. The term goes into Blurt's key
   terms (`BlurtKeyTerms` in the App Group, `KeyTermList` rules: trimmed,
   deduplicated case-insensitively) and rides `keyterms_prompt` on the very
   next dictation. If it began as a selection and you changed it, the
   misheard word in your text is replaced with what you typed. A success
   haptic, and the + shows a check for 1.2 s.

× or an empty save leaves the mode, and so does the keyboard going away. A
hardware keyboard types past the on-screen keys into the app's field; while
the term field is open a short run that appears there right after where the
cursor was is moved into the term and taken back out of the field. The list
itself is edited in Settings → Transcription, which shows the count against
the request's cap of 100 terms.

## Sharing key terms

Settings → Transcription → **Share key terms…** puts the list in the share
sheet as a `.blurtterms` file (JSON — `name`, `from`, `terms`; a declared
document type, `dev.alex.blurt.terms`) with the words as the message text. A
tap on the file in Messages opens Blurt with "Add N key terms?": every term
ticked, untick any, Add merges the rest without duplicates. A
`blurt://terms?add=a,b,c&name=…&from=…` link does the same (`TermPack`,
`ImportTermsView`). A pack is refused over 64 KB, past 100 terms or with a
term, name or sender over 80 characters.

## Adapting to the phone's own keyboard settings

Nothing to configure: key clicks play only if the user has keyboard clicks
on; the return key says what the field asks — send, search, go, done, next,
join — and `return` otherwise; a number, decimal or phone field opens on
the symbols page; capitalisation follows the field's `autocapitalizationType`;
the letter rows follow the phone's first language (AZERTY for French, QWERTZ
for German, Czech, Slovak and Hungarian, QWERTY otherwise); the face follows
the field's `keyboardAppearance`.

## Hands-free

On by default, with a toggle in Settings: a dictation starts the moment the
keyboard comes up in a text field — the same synthetic tap through the
engine's gate, so it latches and the next tap of the element stops it. Only
when the app is listening and nothing is in flight; otherwise the element
sits dimmed and the first tap opens Blurt. When the keyboard leaves the
screen with a dictation it started, it releases a recording (the words still
land, on the clipboard if no keyboard is there) and cancels anything earlier.

## Tokens (`Design/tokens.json` → `Shared/DesignTokens.swift`)

The brand's colours, as the design system defines them and as the phone
uses them. `BlurtBrand` keeps a few of the Mac's names as aliases.

<!-- tokens:begin brand -->

| Token                    | Value     | Swift                        | Use                                                                                                    |
| ------------------------ | --------- | ---------------------------- | ------------------------------------------------------------------------------------------------------ |
| `apple/dark-key`         | `#6B6B6B` | `Brand.appleDarkKey`         | the iPhone keyboard's dark key                                                                         |
| `apple/dark-modifier`    | `#464646` | `Brand.appleDarkModifier`    | the iPhone keyboard's dark modifier key                                                                |
| `apple/dark-surface`     | `#2B2B2B` | `Brand.appleDarkSurface`     | the iPhone keyboard's dark surface                                                                     |
| `apple/light-modifier`   | `#ADB3BC` | `Brand.appleLightModifier`   | the iPhone keyboard's light modifier key                                                               |
| `apple/light-surface`    | `#D1D5DB` | `Brand.appleLightSurface`    | the iPhone keyboard's light surface                                                                    |
| `black`                  | `#000000` | `Brand.black`                | —                                                                                                      |
| `card`                   | `#EBE8E8` | `Brand.card`                 | the warm card fill; the paper theme's surface                                                          |
| `card-border`            | `#DEDBDB` | `Brand.cardBorder`           | the card's hairline; the paper theme's modifier key                                                    |
| `cobolt`                 | `#3923C7` | `Brand.cobolt`               | AssemblyAI's primary violet: the drop, never a key or a surface                                        |
| `green/100`              | `#CCE4D5` | `Brand.green100`             | the design system's UI-and-code green fill (unused on the phone yet)                                   |
| `green/200`              | `#99C8AC` | `Brand.green200`             | the design system's UI-and-code green highlight (unused on the phone yet)                              |
| `green/400`              | `#67AD82` | `Brand.green400`             | the brand hue lifted for dark chrome: the meter, the ring, the wave on ink                             |
| `green/700`              | `#01762F` | `Brand.green700`             | the wordmark green, light chrome (the app's accent in light)                                           |
| `green/mist`             | `#DBF5E6` | `Brand.greenMist`            | the pale green the orb lightens into                                                                   |
| `ink`                    | `#1D1B16` | `Brand.ink`                  | the brand ink: the Mac pill's body, the ink theme's surface                                            |
| `ink/600`                | `#3A362F` | `Brand.ink600`               | the Mac's dark card border                                                                             |
| `ink/700`                | `#33302A` | `Brand.ink700`               | an ordinary key on ink, one step up                                                                    |
| `ink/800`                | `#26231E` | `Brand.ink800`               | a modifier key on ink; the Mac's dark card fill                                                        |
| `material/dark-key`      | `#575757` | `Brand.materialDarkKey`      | a key on the system's dark keyboard material (measured, iOS 27): the container case                    |
| `material/dark-modifier` | `#474747` | `Brand.materialDarkModifier` | a modifier key on the system's dark material                                                           |
| `material/dark-surface`  | `#373737` | `Brand.materialDarkSurface`  | the system's dark keyboard material (measured, iOS 27)                                                 |
| `material/light-surface` | `#E2E3E8` | `Brand.materialLightSurface` | the system's light keyboard material (measured, iOS 27): what the gallery stands under a clear surface |
| `neutral/300`            | `#D2D1D0` | `Brand.neutral300`           | black-100: the lightest warm grey                                                                      |
| `neutral/500`            | `#A5A4A2` | `Brand.neutral500`           | black-200: mono labels on the dark face                                                                |
| `neutral/700`            | `#777673` | `Brand.neutral700`           | black-300: muted text and mono labels on the light face                                                |
| `neutral/900`            | `#4A4945` | `Brand.neutral900`           | black-400: body text on the light face                                                                 |
| `orange`                 | `#E67F36` | `Brand.orange`               | the error word and ring, cancel, the Full Access note; never a red body                                |
| `paper/200`              | `#ECEBE5` | `Brand.paper200`             | neutral-100: the light face's surface                                                                  |
| `paper/300`              | `#DAD7CB` | `Brand.paper300`             | neutral-200: a modifier key on the light face                                                          |
| `paper/400`              | `#C7C3B2` | `Brand.paper400`             | neutral-300: hairlines and field borders on the light face                                             |
| `paper/page`             | `#FDFCF8` | `Brand.paperPage`            | the design system's page: the app's light ground                                                       |
| `paper/tint`             | `#F5F3EB` | `Brand.paperTint`            | the warm off-white one step in: light cards, dark legends                                              |
| `violet/iris`            | `#887BDD` | `Brand.violetIris`           | the orb gradient's upper violet stop                                                                   |
| `violet/lavender`        | `#D7D3F4` | `Brand.violetLavender`       | the orb's lightest violet: its top and the gradient's ends                                             |
| `violet/periwinkle`      | `#B0A7E9` | `Brand.violetPeriwinkle`     | the orb's mid violet: the drop's halo                                                                  |
| `warm-white`             | `#F2EEE6` | `Brand.warmWhite`            | key legends on ink: warm white on warm ink                                                             |
| `white`                  | `#FFFFFF` | `Brand.white`                | —                                                                                                      |

<!-- tokens:end brand -->

The keyboard's semantic colours — what a Figma component binds to — and the
app's catalog colours:

<!-- tokens:begin keyboard -->

| Token                   | Value                                      | Swift                         | Use                                                                      |
| ----------------------- | ------------------------------------------ | ----------------------------- | ------------------------------------------------------------------------ |
| `app/accent-dark`       | `#67AD82` (`brand.green/400`)              | `Keyboard.appAccentDark`      | the catalog's AccentColor in dark                                        |
| `app/accent-light`      | `#01762F` (`brand.green/700`)              | `Keyboard.appAccentLight`     | the catalog's AccentColor in light                                       |
| `app/card-border-dark`  | `#3A362F` (`brand.ink/600`)                | `Keyboard.appCardBorderDark`  | the catalog's CardBorder in dark                                         |
| `app/card-border-light` | `#C7C3B2` (`brand.paper/400`)              | `Keyboard.appCardBorderLight` | the catalog's CardBorder in light                                        |
| `app/card-fill-dark`    | `#26231E` (`brand.ink/800`)                | `Keyboard.appCardFillDark`    | the catalog's CardFill in dark                                           |
| `app/card-fill-light`   | `#F5F3EB` (`brand.paper/tint`)             | `Keyboard.appCardFillLight`   | the catalog's CardFill in light                                          |
| `app/cta-dark`          | `#67AD82` (`brand.green/400`)              | `Keyboard.appCtaDark`         | the catalog's CTA in dark: the site's button green                       |
| `app/cta-light`         | `#01762F` (`brand.green/700`)              | `Keyboard.appCtaLight`        | the catalog's CTA in light: the one green button                         |
| `app/cta-text-dark`     | `#1D1B16` (`brand.ink`)                    | `Keyboard.appCtaTextDark`     | the catalog's CTAText in dark: ink on green, as the site                 |
| `app/cta-text-light`    | `#FFFFFF` (`brand.white`)                  | `Keyboard.appCtaTextLight`    | the catalog's CTAText in light                                           |
| `app/muted-dark`        | `#A5A4A2` (`brand.neutral/500`)            | `Keyboard.appMutedDark`       | the catalog's Muted in dark                                              |
| `app/muted-light`       | `#777673` (`brand.neutral/700`)            | `Keyboard.appMutedLight`      | the catalog's Muted in light: eyebrows, captions, secondary text         |
| `app/page-dark`         | `#1D1B16` (`brand.ink`)                    | `Keyboard.appPageDark`        | the catalog's Page in dark: ink, the website's ground                    |
| `app/page-light`        | `#FDFCF8` (`brand.paper/page`)             | `Keyboard.appPageLight`       | the catalog's Page in light: the design system's page                    |
| `app/text-dark`         | `#F5F3EB` (`brand.paper/tint`)             | `Keyboard.appTextDark`        | the catalog's Text in dark                                               |
| `app/text-light`        | `#1D1B16` (`brand.ink`)                    | `Keyboard.appTextLight`       | the catalog's Text in light                                              |
| `kb/cancel`             | `#E67F36` (`brand.orange`)                 | `Keyboard.kbCancel`           | the panel's cancel ×                                                     |
| `kb/field`              | `#33302A` (`themes.dark/field`)            | `Keyboard.kbField`            | the key-term field                                                       |
| `kb/field-border`       | `#3A362F` (`themes.dark/field-border`)     | `Keyboard.kbFieldBorder`      | the field's hairline                                                     |
| `kb/full-access-note`   | `#E67F36` (`brand.orange`)                 | `Keyboard.kbFullAccessNote`   | the one line of words the keyboard ever shows                            |
| `kb/key`                | `#33302A` (`themes.dark/key`)              | `Keyboard.kbKey`              | an ordinary key                                                          |
| `kb/key-modifier`       | `#26231E` (`themes.dark/key-modifier`)     | `Keyboard.kbKeyModifier`      | shift, delete, globe, return, 123, cancel                                |
| `kb/legend`             | `#F5F3EB` (`themes.dark/legend`)           | `Keyboard.kbLegend`           | key legends and bare glyphs                                              |
| `kb/legend-secondary`   | `#A5A4A2` (`themes.dark/legend-secondary`) | `Keyboard.kbLegendSecondary`  | the mono word labels (123, ABC, return, space) and the + at rest         |
| `kb/notice-error`       | `#E67F36` (`brand.orange`)                 | `Keyboard.kbNoticeError`      | the solid ring and glyph for an error                                    |
| `kb/popup`              | `#33302A` (`themes.dark/popup`)            | `Keyboard.kbPopup`            | the letter pop-up                                                        |
| `kb/signal`             | `#67AD82` (`themes.dark/signal`)           | `Keyboard.kbSignal`           | the wave, the caret, the saved check                                     |
| `kb/surface`            | `#1D1B16` (`themes.dark/surface`)          | `Keyboard.kbSurface`          | the design face's surface (Figma binds to kb/*; Swift reads the palette) |

<!-- tokens:end keyboard -->

<!-- tokens:begin gradients -->

<!-- tokens:end gradients -->

## Metrics and motion

Every size, gap, radius, opacity and duration the views use. The heights in
`KeyboardLayout.height` are derived from these, and `LayoutArithmeticTests`
pins the derivation.

<!-- tokens:begin metrics -->

| Token                        | Points    | Swift                              | Use                                                                                                                                                                                                                                                                 |
| ---------------------------- | --------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `addterm/inset`              | `6`       | `Metrics.addtermInset`             | the + from the panel's corner                                                                                                                                                                                                                                       |
| `app/button-height`          | `40`      | `Metrics.appButtonHeight`          | the brand's button                                                                                                                                                                                                                                                  |
| `app/button-pad`             | `12`      | `Metrics.appButtonPad`             | its side padding                                                                                                                                                                                                                                                    |
| `app/card-pad`               | `16`      | `Metrics.appCardPad`               | inside a card                                                                                                                                                                                                                                                       |
| `app/chip-gap`               | `8`       | `Metrics.appChipGap`               | between chips                                                                                                                                                                                                                                                       |
| `app/chip-pad-x`             | `12`      | `Metrics.appChipPadX`              | a style chip's side padding                                                                                                                                                                                                                                         |
| `app/chip-pad-y`             | `8`       | `Metrics.appChipPadY`              | and its top and bottom                                                                                                                                                                                                                                              |
| `app/header-height`          | `44`      | `Metrics.appHeaderHeight`          | the home header: wordmark and gear                                                                                                                                                                                                                                  |
| `app/hero-gap`               | `14`      | `Metrics.appHeroGap`               | between the hero's pieces                                                                                                                                                                                                                                           |
| `app/hero-pad`               | `20`      | `Metrics.appHeroPad`               | inside the hero card                                                                                                                                                                                                                                                |
| `app/icon`                   | `20`      | `Metrics.appIcon`                  | the header's gear, the copy glyph                                                                                                                                                                                                                                   |
| `app/line-gap`               | `6`       | `Metrics.appLineGap`               | between lines of one thought                                                                                                                                                                                                                                        |
| `app/page-pad`               | `20`      | `Metrics.appPagePad`               | the screens' side padding                                                                                                                                                                                                                                           |
| `app/preview-gap`            | `8`       | `Metrics.appPreviewGap`            | between the theme card's two faces                                                                                                                                                                                                                                  |
| `app/section-gap`            | `24`      | `Metrics.appSectionGap`            | between the home screen's sections                                                                                                                                                                                                                                  |
| `app/setup-number-width`     | `24`      | `Metrics.appSetupNumberWidth`      | the setup steps' mono numerals                                                                                                                                                                                                                                      |
| `app/stack-gap`              | `12`      | `Metrics.appStackGap`              | between a section's eyebrow and its content, and between cards                                                                                                                                                                                                      |
| `card/border`                | `1`       | `Metrics.cardBorder`               | the card's hairline                                                                                                                                                                                                                                                 |
| `card/radius`                | `12`      | `Metrics.cardRadius`               | the app's cards (radius/card)                                                                                                                                                                                                                                       |
| `caret/height`               | `20`      | `Metrics.caretHeight`              | —                                                                                                                                                                                                                                                                   |
| `caret/lead`                 | `1`       | `Metrics.caretLead`                | the caret's gap from the text                                                                                                                                                                                                                                       |
| `caret/radius`               | `1`       | `Metrics.caretRadius`              | —                                                                                                                                                                                                                                                                   |
| `caret/width`                | `2`       | `Metrics.caretWidth`               | —                                                                                                                                                                                                                                                                   |
| `glyph/hit`                  | `32`      | `Metrics.glyphHit`                 | the +, × and ✓ touch targets                                                                                                                                                                                                                                        |
| `grille/bar-height`          | `28`      | `Metrics.grilleBarHeight`          | —                                                                                                                                                                                                                                                                   |
| `grille/bar-width`           | `64`      | `Metrics.grilleBarWidth`           | the grille in the voice bar                                                                                                                                                                                                                                         |
| `grille/dot`                 | `2`       | `Metrics.grilleDot`                | a dot's diameter                                                                                                                                                                                                                                                    |
| `grille/glint-arm`           | `1.6`     | `Metrics.grilleGlintArm`           | the cross glint's vertical arm, as a fraction of the grille's height                                                                                                                                                                                                |
| `grille/glint-width`         | `1`       | `Metrics.grilleGlintWidth`         | the glint's arms                                                                                                                                                                                                                                                    |
| `grille/home-height`         | `108`     | `Metrics.grilleHomeHeight`         | —                                                                                                                                                                                                                                                                   |
| `grille/home-width`          | `240`     | `Metrics.grilleHomeWidth`          | the grille on the home screen                                                                                                                                                                                                                                       |
| `grille/panel-height`        | `72`      | `Metrics.grillePanelHeight`        | —                                                                                                                                                                                                                                                                   |
| `grille/panel-width`         | `160`     | `Metrics.grillePanelWidth`         | the grille in the panel                                                                                                                                                                                                                                             |
| `grille/pitch`               | `4`       | `Metrics.grillePitch`              | the dot lattice: one dot every                                                                                                                                                                                                                                      |
| `grille/sheen-width`         | `0.35`    | `Metrics.grilleSheenWidth`         | the sheen's band, as a fraction of the width                                                                                                                                                                                                                        |
| `key/abc-width-402`          | `43.333`  | `Metrics.keyAbcWidth402`           | 123 and the globe at 402 pt: the iPhone's                                                                                                                                                                                                                           |
| `key/gap`                    | `6`       | `Metrics.keyGap`                   | between keys, the iPhone's                                                                                                                                                                                                                                          |
| `key/height`                 | `43`      | `Metrics.keyHeight`                | every key: the iPhone's cap height (apple-geometry.json)                                                                                                                                                                                                            |
| `key/letter-width-402`       | `33.5`    | `Metrics.keyLetterWidth402`        | a letter key at 402 pt: (width − 2 × margin/side − 9 × key/gap) / 10                                                                                                                                                                                                |
| `key/min-width`              | `43.333`  | `Metrics.keyMinWidth`              | a key that isn't given a width: the iPhone's 123 key at 402 pt                                                                                                                                                                                                      |
| `key/pad`                    | `4`       | `Metrics.keyPad`                   | a legend's side padding on a min-width key                                                                                                                                                                                                                          |
| `key/radius`                 | `8`       | `Metrics.keyRadius`                | flat keys, one colour at this corner: the iPhone's (fitted 8.17)                                                                                                                                                                                                    |
| `key/reference-width`        | `402`     | `Metrics.keyReferenceWidth`        | the width the @402 tokens were measured at (iPhone 18 Pro); widths scale from it                                                                                                                                                                                    |
| `key/return-width-402`       | `92.667`  | `Metrics.keyReturnWidth402`        | return at 402 pt: two 123 keys and a gap                                                                                                                                                                                                                            |
| `key/side-gap`               | `13.667`  | `Metrics.keySideGap`               | shift and delete stand this far from the letters: the iPhone's                                                                                                                                                                                                      |
| `key/side-width-402`         | `45.583`  | `Metrics.keySideWidth402`          | shift and delete at 402 pt: what seven letters and the side gaps leave, halved (measured 45.5)                                                                                                                                                                      |
| `key/space-width-402`        | `191.667` | `Metrics.keySpaceWidth402`         | space at 402 pt beside 123, the globe and return: what is left (measured 191.333)                                                                                                                                                                                   |
| `layout/full`                | `270`     | `Metrics.layoutFull`               | margin/vertical + voicebar/height + 4 × key/height + 3 × row/gap + margin/bottom-keys                                                                                                                                                                               |
| `layout/panel`               | `216`     | `Metrics.layoutPanel`              | chosen: room for the 96 orb over one key row                                                                                                                                                                                                                        |
| `layout/slim`                | `60`      | `Metrics.layoutSlim`               | 2 × margin/vertical + voicebar/height                                                                                                                                                                                                                               |
| `margin/bottom-keys`         | `13`      | `Metrics.marginBottomKeys`         | under a bottom row of keys (the full keyboard, the panel): the iPhone's                                                                                                                                                                                             |
| `margin/side`                | `6.5`     | `Metrics.marginSide`               | at the keyboard's sides: the iPhone's cap margin, (402 − 10 letters − 9 gaps) / 2                                                                                                                                                                                   |
| `margin/vertical`            | `8`       | `Metrics.marginVertical`           | the keyboard's top, and the slim bar's bottom                                                                                                                                                                                                                       |
| `opacity/disabled`           | `0.4`     | `Metrics.opacityDisabled`          | the + without Full Access                                                                                                                                                                                                                                           |
| `opacity/glint`              | `0.95`    | `Metrics.opacityGlint`             | the cross glint when the words land                                                                                                                                                                                                                                 |
| `opacity/grain-dark`         | `0.14`    | `Metrics.opacityGrainDark`         | film grain over the dark face: matte, the brand's texture                                                                                                                                                                                                           |
| `opacity/grain-light`        | `0.08`    | `Metrics.opacityGrainLight`        | film grain over the light face: paper, lighter                                                                                                                                                                                                                      |
| `opacity/grille-rest`        | `0.55`    | `Metrics.opacityGrilleRest`        | the dots at rest, over the key colour                                                                                                                                                                                                                               |
| `opacity/hairline`           | `0.5`     | `Metrics.opacityHairline`          | —                                                                                                                                                                                                                                                                   |
| `opacity/legend`             | `1`       | `Metrics.opacityLegend`            | key legends over the cap; below 1 they sit back                                                                                                                                                                                                                     |
| `opacity/legend-muted`       | `0.5`     | `Metrics.opacityLegendMuted`       | the + at rest                                                                                                                                                                                                                                                       |
| `opacity/off`                | `0.6`     | `Metrics.opacityOff`               | the element when Blurt isn't ready — dim and still, but there: a tap opens the app                                                                                                                                                                                  |
| `opacity/placeholder`        | `0.4`     | `Metrics.opacityPlaceholder`       | the field's placeholder                                                                                                                                                                                                                                             |
| `opacity/popup-shadow`       | `0.12`    | `Metrics.opacityPopupShadow`       | —                                                                                                                                                                                                                                                                   |
| `opacity/press-brighten`     | `0.15`    | `Metrics.opacityPressBrighten`     | a key lightens this much while pressed                                                                                                                                                                                                                              |
| `opacity/pressed`            | `0.85`    | `Metrics.opacityPressed`           | a brand button while pressed: a colour change, no lift                                                                                                                                                                                                              |
| `opacity/sheen`              | `0.22`    | `Metrics.opacitySheen`             | the light passing over the element at rest: chrome catching light                                                                                                                                                                                                   |
| `opacity/surface-vignette`   | `0`       | `Metrics.opacitySurfaceVignette`   | a soft darkening toward the surface's edges; 0 is none                                                                                                                                                                                                              |
| `opacity/term-cancel`        | `0.7`     | `Metrics.opacityTermCancel`        | the field's ×                                                                                                                                                                                                                                                       |
| `panel/spacing`              | `12`      | `Metrics.panelSpacing`             | between the panel's orb and its key row                                                                                                                                                                                                                             |
| `picker/preview-width`       | `393`     | `Metrics.pickerPreviewWidth`       | the theme card draws the keyboard at this width                                                                                                                                                                                                                     |
| `picker/radius`              | `10`      | `Metrics.pickerRadius`             | the theme card's preview corners                                                                                                                                                                                                                                    |
| `picker/scale`               | `0.42`    | `Metrics.pickerScale`              | then scales it to fit two across                                                                                                                                                                                                                                    |
| `popup/extra-width`          | `18`      | `Metrics.popupExtraWidth`          | the letter pop-up is the key width plus this                                                                                                                                                                                                                        |
| `popup/height`               | `56`      | `Metrics.popupHeight`              | —                                                                                                                                                                                                                                                                   |
| `popup/offset`               | `58`      | `Metrics.popupOffset`              | the pop-up sits this far above the key                                                                                                                                                                                                                              |
| `popup/radius`               | `10`      | `Metrics.popupRadius`              | —                                                                                                                                                                                                                                                                   |
| `popup/shadow-radius`        | `8`       | `Metrics.popupShadowRadius`        | the one thing that floats                                                                                                                                                                                                                                           |
| `popup/shadow-y`             | `2`       | `Metrics.popupShadowY`             | —                                                                                                                                                                                                                                                                   |
| `radius/button`              | `4`       | `Metrics.radiusButton`             | the brand's buttons and the grille: rectangular, never a pill                                                                                                                                                                                                       |
| `radius/card`                | `12`      | `Metrics.radiusCard`               | the brand's cards                                                                                                                                                                                                                                                   |
| `radius/hero`                | `16`      | `Metrics.radiusHero`               | the brand's featured cards                                                                                                                                                                                                                                          |
| `radius/input`               | `8`       | `Metrics.radiusInput`              | the brand's inputs: the key-term field                                                                                                                                                                                                                              |
| `ribs/rest-height`           | `16`      | `Metrics.ribsRestHeight`           | —                                                                                                                                                                                                                                                                   |
| `ribs/rest-width`            | `40`      | `Metrics.ribsRestWidth`            | the ribs asleep: the wave's own bars at rest                                                                                                                                                                                                                        |
| `row/gap`                    | `11`      | `Metrics.rowGap`                   | between rows, the iPhone's                                                                                                                                                                                                                                          |
| `slim/spacing`               | `8`       | `Metrics.slimSpacing`              | between the slim bar's keys                                                                                                                                                                                                                                         |
| `streak/arm`                 | `1.4`     | `Metrics.streakArm`                | the landing flash's vertical arm, as a fraction of the box's height                                                                                                                                                                                                 |
| `streak/height`              | `2`       | `Metrics.streakHeight`             | the light streak while recording                                                                                                                                                                                                                                    |
| `streak/line`                | `1`       | `Metrics.streakLine`               | the hairline at rest                                                                                                                                                                                                                                                |
| `streak/point`               | `4`       | `Metrics.streakPoint`              | the bright point at the centre                                                                                                                                                                                                                                      |
| `surface/paint`              | `0`       | `Metrics.surfacePaint`             | 1 paints the face's surface under the keys; 0 leaves it clear, so the host's own keyboard material (iOS 26's rounded container, which insets a third-party keyboard and cannot be painted over) is the surface, seamlessly, and the keys take the container colours |
| `surface/vignette-end`       | `0.75`    | `Metrics.surfaceVignetteEnd`       | where it is full                                                                                                                                                                                                                                                    |
| `surface/vignette-start`     | `0.3`     | `Metrics.surfaceVignetteStart`     | where the vignette begins, as a fraction of the keyboard's width                                                                                                                                                                                                    |
| `term/border`                | `1`       | `Metrics.termBorder`               | the field's hairline                                                                                                                                                                                                                                                |
| `term/gap`                   | `8`       | `Metrics.termGap`                  | × · field · ✓                                                                                                                                                                                                                                                       |
| `term/height`                | `36`      | `Metrics.termHeight`               | the key-term field's capsule                                                                                                                                                                                                                                        |
| `term/inset`                 | `2`       | `Metrics.termInset`                | the field row's side inset                                                                                                                                                                                                                                          |
| `term/pad`                   | `14`      | `Metrics.termPad`                  | the field's side padding                                                                                                                                                                                                                                            |
| `term/radius`                | `8`       | `Metrics.termRadius`               | the key-term field: the brand's input corners (radius/input)                                                                                                                                                                                                        |
| `voice/bar-height`           | `32`      | `Metrics.voiceBarHeight`           | —                                                                                                                                                                                                                                                                   |
| `voice/bar-width`            | `160`     | `Metrics.voiceBarWidth`            | the voice element's box in the voice bar — the most it takes (the ribs awake, the streak); the + sits beside what shows                                                                                                                                             |
| `voice/home-height`          | `112`     | `Metrics.voiceHomeHeight`          | —                                                                                                                                                                                                                                                                   |
| `voice/home-width`           | `280`     | `Metrics.voiceHomeWidth`           | the box on the home screen                                                                                                                                                                                                                                          |
| `voice/panel-height`         | `88`      | `Metrics.voicePanelHeight`         | —                                                                                                                                                                                                                                                                   |
| `voice/panel-width`          | `300`     | `Metrics.voicePanelWidth`          | the box in the panel                                                                                                                                                                                                                                                |
| `voice/press-scale`          | `0.94`    | `Metrics.voicePressScale`          | the element while pressed                                                                                                                                                                                                                                           |
| `voicebar/addterm-clearance` | `12`      | `Metrics.voicebarAddtermClearance` | between the element and the +                                                                                                                                                                                                                                       |
| `voicebar/height`            | `44`      | `Metrics.voicebarHeight`           | the voice row, where the system puts its suggestion bar                                                                                                                                                                                                             |
| `voicebar/note-gap`          | `10`      | `Metrics.voicebarNoteGap`          | between the orb and the Full Access note                                                                                                                                                                                                                            |
| `wave/bar`                   | `2`       | `Metrics.waveBar`                  | a wave bar's width                                                                                                                                                                                                                                                  |
| `wave/bar-height`            | `24`      | `Metrics.waveBarHeight`            | —                                                                                                                                                                                                                                                                   |
| `wave/gap`                   | `2`       | `Metrics.waveGap`                  | between wave bars                                                                                                                                                                                                                                                   |
| `wave/home-height`           | `44`      | `Metrics.waveHomeHeight`           | —                                                                                                                                                                                                                                                                   |
| `wave/panel-height`          | `40`      | `Metrics.wavePanelHeight`          | —                                                                                                                                                                                                                                                                   |
| `wordmark/height`            | `22`      | `Metrics.wordmarkHeight`           | —                                                                                                                                                                                                                                                                   |

<!-- tokens:end metrics -->

Motion. Nothing springs or snaps; only the press answers at once. Colour and
fill changes ease over the brand's transition; everything else moves on the
house curve (`ease/signature`, `cubic-bezier(0.22, 1, 0.36, 1)`).

<!-- tokens:begin motion -->

| Token            | Value           | Swift                  | Use                                                           |
| ---------------- | --------------- | ---------------------- | ------------------------------------------------------------- |
| `caret`          | `0.5`           | `Motion.caret`         | the caret's blink                                             |
| `colour`         | `0.2`           | `Motion.colour`        | a colour or fill changing state: the brand's transition       |
| `ease/signature` | `0.22,1,0.36,1` | `Motion.easeSignature` | the house curve for everything that moves; nothing springs    |
| `flip`           | `0.25`          | `Motion.flip`          | the panel's carousel                                          |
| `glint-life`     | `0.5`           | `Motion.glintLife`     | a facet's flash while recording                               |
| `height-change`  | `0.25`          | `Motion.heightChange`  | the keyboard resizing                                         |
| `key-press`      | `0.08`          | `Motion.keyPress`      | a key lighting                                                |
| `landing`        | `0.6`           | `Motion.landing`       | the glint when the words land                                 |
| `press`          | `0.1`           | `Motion.press`         | the orb's press; the one thing that answers at once           |
| `ring-period`    | `1.6`           | `Motion.ringPeriod`    | one turn of the ring, the Mac's cadence                       |
| `sheen`          | `4`             | `Motion.sheen`         | one pass of the light over the element at rest                |
| `sheen-working`  | `1.6`           | `Motion.sheenWorking`  | and while something is happening: the ring's cadence          |
| `state-fade`     | `0.5`           | `Motion.stateFade`     | every other change on the key: the ring, a glyph, the dimming |
| `term-swap`      | `0.4`           | `Motion.termSwap`      | the voice bar becoming the field                              |
| `wave-fade`      | `0.7`           | `Motion.waveFade`      | the orb and the wave crossing, either way                     |

<!-- tokens:end motion -->

## The app's screens (`BlurtiOS/Sources/`)

The Blurt landing page on a phone, in the phone's appearance: the page under
the brand's grain; the wordmark (tinted with the accent) and the gear across
the top; sections under mono eyebrows; serif headlines (Oceanic Text, 34),
body in UN 11ST (16, captions 14); cards with 12 pt corners and a 1 pt
hairline (the hero 16), no shadows; chips and buttons rectangular at 4 pt,
buttons 40 pt tall with their label in uppercase mono, one green button per
row (Cam's rule) and a hairline one beside it, a colour change on press and
never a lift. Glyphs are SF Symbols — the platform's — where the web brand
uses Material Symbols.

**Home** (`HomeView`, `HomeHero`, `SetupCard`, `StyleChips`, `RecentSection`,
`HomeStatus` for the words): the setup card only while something is missing,
its three steps numbered `01 02 03` in mono; the hero — `STATUS`, the
headline (Not listening · Ready to dictate · Connecting… · Listening… ·
Transcribing… · Pasted · Copied · the error), the line under it, the voice
element at home size, `START LISTENING` (refused without a key, with a line
saying so) or the hairline `STOP LISTENING`, and "Dictate here, to the
clipboard" as a text button; `STYLE` and the chips, the active one filled;
`RECENT` and the cards (three lines, the style as a green mono tag, the
time, a copy button); `POWERED BY ASSEMBLYAI`.

**Settings** (`SettingsView`): a form on the page, its sections under
eyebrows — Keyboard (layout, theme, hands-free), Listening (the window),
Transcription (enhanced transcripts, output styles, key terms with the
contact-name count, sharing), Account (sign-in stub; the API key in debug
builds), About. The theme picker shows each theme's two faces side by side.
Styles, the import sheet and the key entry share the form's chrome
(`brandForm()`).

`-BlurtSettings` opens Settings as the root for a screenshot; `xcrun simctl
ui booted appearance dark` before any capture for the dark appearance;
`-BlurtStartListening` opens the mic at launch.

## Feedback and accessibility

Haptics (`KeyboardModel.haptics`): medium impact on `recording`, light on the
stop, `.success` on pasted/copied, `.error` on error — with no words on the
keyboard, they are half of the feedback. The DX7 start/stop cues play in the
app, not the keyboard. The mic control is a button labelled Dictate / Stop
dictation / Start Blurt and speaks the error message; the element itself is
hidden from VoiceOver. Reduce Motion stops the sheen and the glints; heights
still follow the level.

## The two processes, and every number

The app listens and transcribes; the keyboard is a remote control. They talk
over the App Group's `UserDefaults` (payloads as JSON) plus Darwin
notifications that carry nothing and just say "look" (`SharedState.swift`).

| Rule                   | Value                                                                                          | Why                                                                                                      |
| ---------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| presence               | heartbeat 5 s (app), 4 s (keyboard); window 15 s                                               | more than twice a heartbeat, so one missed beat isn't absence; a killed process is absent within seconds |
| listening              | window not lapsed **and** app seen within 15 s                                                 | a killed app, or a phone call, with the window's end still in the future                                 |
| result freshness       | 10 s                                                                                           | a notification held for a suspended keyboard arrives minutes late                                        |
| result addressing      | `recipient` = the keyboard instance last seen                                                  | two live keyboards (two host apps) must not both insert                                                  |
| result delivery        | the app waits 3 s (poll 250 ms) for the keyboard to take the result; else clipboard + "Copied" | "Pasted" is never a guess                                                                                |
| command freshness      | 10 s                                                                                           | a held press from minutes ago must not start a dictation on resume                                       |
| command retry          | one re-signal after 600 ms with no phase change                                                | a missed Darwin notification would leave the gate latched over nothing                                   |
| phase staleness        | notices 3 s (max dwell 2 s + 1); in flight 130 s (the 120 s cap + 10)                          | the keyboard reads the snapshot on every appearance                                                      |
| notice dwell           | pasted 1.2 s; copied, error 2 s                                                                | the Mac's 0.8 / 1.6 s, a little longer with no hover                                                     |
| press delay on the mic | 90 ms                                                                                          | a swipe that starts on the key never starts a dictation it must then cancel                              |
| tap travel             | 12 pt (keys), 24 pt (mic), swipe ≥ 48 pt horizontal and 1.5× the vertical                      | the carousel's swipe never types or dictates                                                             |
| level publish          | every 80 ms while recording                                                                    | the element's meter, off the capture path's back                                                         |
| lexicon refresh        | hourly                                                                                         | thousands of contacts on a keyboard memory budget                                                        |
| height change          | 0.25 s; constraint priority 999                                                                | iOS honours a keyboard's height at just under required                                                   |
| the visual numbers     | see Metrics and motion above                                                                   | generated from `Design/tokens.json`; the views carry no literals                                         |
| term packs             | ≤ 64 KB, ≤ 100 terms, ≤ 80 characters each                                                     | the request's cap; unbounded input from a stranger                                                       |

Tests pin the rules that can be pinned (`BlurtiOSTests`: the contract, the
gate, results, the term field, the feed, the layout arithmetic, Apple's
geometry, the interaction rules, the voice state, the home's words, the
fonts, the tokens); anything that gains a number here should gain a line
there.

## Where Blurt diverges from the brand system, on purpose

- Green is the UI signal (the system says cobolt-only): Cam's rule for the
  collab brand — inside the Assembly palette, off primary cobolt. Cobolt and
  its violets appear only as light: the glint's fringe, the streak's tips.
- SF Pro for the letter keys and SF Symbols for every glyph (the web uses
  Material Symbols): a keyboard has to be native under the fingers.
- The keys' corners are the iPhone's (8), not the brand's 4: Apple's exact
  geometry wins on the keyboard; the brand's radii hold everywhere else.

## Next

The pick between a, b and c; the losers and the `-BlurtGalleryVoice` switch
go, and the winner's tokens lose their prefix. Then: the keyboard's autocorrect
and suggestion bar; onboarding as a stepped flow once sign-in exists; the
app's cues on the phase edges; the curated themes as brand value sets; the
Figma file rebuilt from the tokens.
