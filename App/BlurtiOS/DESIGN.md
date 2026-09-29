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

On the phone, every colour and number the views draw with lives once, in
`Design/tokens.json`, and is fanned out from there: `Shared/DesignTokens.swift`
(what the views read), the tables in this file marked `tokens:begin` /
`tokens:end`, and the app's three asset-catalog colour sets are all generated
by `scripts/design-tokens.swift`. Edit the JSON (or export it from Figma, see
below), run `scripts/design-sync.sh`, commit; `scripts/check.sh` runs
`design-sync.sh --check` and fails on drift. The views carry no design
literals — the same script lints them — so a number that changes in Figma
changes everywhere or nowhere.

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

For the design loop the capture has to be the same pixels every time, and it
has to be the keyboard's pixels alone. Two switches do that:
`-BlurtGalleryStill` holds every motion at time zero (the ring, the meter's
wave, the orb's fluid and its grain — what Reduce Motion does) and
`-BlurtGalleryBare` draws the first row by itself inside a 2 pt `#FF00FF`
registration border. `-BlurtOrb <size> <off|idle|listening|working|landed>`
renders one orb fill the same way, for Figma's image fills. The scripts on
top:

```bash
scripts/design-capture.sh --layout panel --states idle,recording,error,term --themes system,system-dark,ink
    # builds once, captures each still, crops it → .build/design/captures/<layout>-<state>-<theme>@3x.png
scripts/ios-record.sh --layout panel --theme ink --frames 0,0.35,0.7
    # one 11.7 s loop of the `live` walk, cropped, plus stills at those seconds
swift scripts/design-diff.swift diff figma.png sim.png --out triptych.png --json metrics.json --mask x,y,w,h
    # both to sRGB, then AE (pixels over the threshold) and RMSE, outside the masks and per mask
swift scripts/design-diff.swift sheet --out sheet.png --columns 4 "panel · idle · ink=a.png" …
scripts/design-sync.sh          # tokens.json → DesignTokens.swift, these tables, the colour sets
scripts/design-sync.sh --check  # what check.sh runs: drift and design literals
```

`ios-sim.sh --no-build` reuses the last build, so a loop of forty captures
builds once. The capture device is the iPhone 18 Pro (402 pt → 1206 px at 3×,
the Figma frames' width), pinned in `scripts/ios-sim.sh`; a crop that is not
the layout's height × the scale fails rather than being resampled.

## Figma

The keyboard is designed in Figma and built from the export. The file is
**Blurt Keyboard** (Neil's personal Figma space until the design moves into the
AssemblyAI org; key and approved version in `Design/tokens.json` › `figma`),
three pages: `01 Foundations` (the variables below as six collections, text and
effect styles, specimens), `02 Components` (Key, LetterPopup, Orb, MicKey,
WaveformMeter, TermField, AddTermKey, CancelKey, VoiceBar), `03 Layouts` (the
three layouts at 402 pt — iPhone 18 Pro, the simulator this repo captures on —
as state rows named `<layout>/<state>/<theme>` exactly as the gallery captions
them, an Apple-keyboard reference overlay, redlines, the motion table, and the
review boards). The file is rebuilt from the scripts in `Design/figma/`, so the
scripts, not the file, are the durable record.

The loop: design and approve in Figma (a named version) → export the variables
to `Design/tokens.json` → `scripts/design-sync.sh` → the views → captures from
the gallery compared against the Figma exports. The orb is the one exception
that goes the other way: `MeshGradient` plus grain cannot be drawn natively in
Figma, so the app renders deterministic stills that Figma uses as image fills,
and Figma holds the parameters (`orb/*`, `opacity/orb-light`, `opacity/grain`,
the drop timings).

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

<!-- tokens:begin themes -->

| Face    | Surface   | Key       | Modifier  | Legend    | Secondary | Signal    | Pop-up    | Field     | Field border | Notice    |
| ------- | --------- | --------- | --------- | --------- | --------- | --------- | --------- | --------- | ------------ | --------- |
| `light` | `#ECEBE5` | `#FFFFFF` | `#DAD7CB` | `#1D1B16` | `#777673` | `#01762F` | `#FFFFFF` | `#FFFFFF` | `#C7C3B2`    | `#E67F36` |
| `dark`  | `#1D1B16` | `#33302A` | `#26231E` | `#F5F3EB` | `#A5A4A2` | `#67AD82` | `#33302A` | `#33302A` | `#3A362F`    | `#E67F36` |

<!-- tokens:end themes -->

The picker's one-liners (the vibes) live with the palettes in
`KeyboardPalette.swift`; the colours are the tokens above. The orb and the ring
are the same in every theme; the wave takes the
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

## Tokens (`Design/tokens.json` → `Shared/DesignTokens.swift`)

The brand's colours, as the Mac defines them and as the phone extends them.
`BlurtBrand` keeps its names (`green`, `greenOnDark`, `ink`, …) as aliases of
these, so the Mac's vocabulary still reads at the call sites.

<!-- tokens:begin brand -->

| Token                  | Value     | Swift                      | Use                                                                        |
| ---------------------- | --------- | -------------------------- | -------------------------------------------------------------------------- |
| `apple/dark-key`       | `#6B6B6B` | `Brand.appleDarkKey`       | the iPhone keyboard's dark key                                             |
| `apple/dark-modifier`  | `#464646` | `Brand.appleDarkModifier`  | the iPhone keyboard's dark modifier key                                    |
| `apple/dark-surface`   | `#2B2B2B` | `Brand.appleDarkSurface`   | the iPhone keyboard's dark surface                                         |
| `apple/light-modifier` | `#ADB3BC` | `Brand.appleLightModifier` | the iPhone keyboard's light modifier key                                   |
| `apple/light-surface`  | `#D1D5DB` | `Brand.appleLightSurface`  | the iPhone keyboard's light surface                                        |
| `black`                | `#000000` | `Brand.black`              | —                                                                          |
| `card`                 | `#EBE8E8` | `Brand.card`               | the warm card fill; the paper theme's surface                              |
| `card-border`          | `#DEDBDB` | `Brand.cardBorder`         | the card's hairline; the paper theme's modifier key                        |
| `cobolt`               | `#3923C7` | `Brand.cobolt`             | AssemblyAI's primary violet: the drop, never a key or a surface            |
| `green/100`            | `#CCE4D5` | `Brand.green100`           | the design system's UI-and-code green fill (unused on the phone yet)       |
| `green/200`            | `#99C8AC` | `Brand.green200`           | the design system's UI-and-code green highlight (unused on the phone yet)  |
| `green/400`            | `#67AD82` | `Brand.green400`           | the brand hue lifted for dark chrome: the meter, the ring, the wave on ink |
| `green/700`            | `#01762F` | `Brand.green700`           | the wordmark green, light chrome (the app's accent in light)               |
| `green/mist`           | `#DBF5E6` | `Brand.greenMist`          | the pale green the orb lightens into                                       |
| `ink`                  | `#1D1B16` | `Brand.ink`                | the brand ink: the Mac pill's body, the ink theme's surface                |
| `ink/600`              | `#3A362F` | `Brand.ink600`             | the Mac's dark card border                                                 |
| `ink/700`              | `#33302A` | `Brand.ink700`             | an ordinary key on ink, one step up                                        |
| `ink/800`              | `#26231E` | `Brand.ink800`             | a modifier key on ink; the Mac's dark card fill                            |
| `neutral/300`          | `#D2D1D0` | `Brand.neutral300`         | black-100: the lightest warm grey                                          |
| `neutral/500`          | `#A5A4A2` | `Brand.neutral500`         | black-200: mono labels on the dark face                                    |
| `neutral/700`          | `#777673` | `Brand.neutral700`         | black-300: muted text and mono labels on the light face                    |
| `neutral/900`          | `#4A4945` | `Brand.neutral900`         | black-400: body text on the light face                                     |
| `orange`               | `#E67F36` | `Brand.orange`             | the error word and ring, cancel, the Full Access note; never a red body    |
| `paper/200`            | `#ECEBE5` | `Brand.paper200`           | neutral-100: the light face's surface                                      |
| `paper/300`            | `#DAD7CB` | `Brand.paper300`           | neutral-200: a modifier key on the light face                              |
| `paper/400`            | `#C7C3B2` | `Brand.paper400`           | neutral-300: hairlines and field borders on the light face                 |
| `paper/page`           | `#FDFCF8` | `Brand.paperPage`          | the design system's page: the app's light ground                           |
| `paper/tint`           | `#F5F3EB` | `Brand.paperTint`          | the warm off-white one step in: light cards, dark legends                  |
| `violet/iris`          | `#887BDD` | `Brand.violetIris`         | the orb gradient's upper violet stop                                       |
| `violet/lavender`      | `#D7D3F4` | `Brand.violetLavender`     | the orb's lightest violet: its top and the gradient's ends                 |
| `violet/periwinkle`    | `#B0A7E9` | `Brand.violetPeriwinkle`   | the orb's mid violet: the drop's halo                                      |
| `warm-white`           | `#F2EEE6` | `Brand.warmWhite`          | key legends on ink: warm white on warm ink                                 |
| `white`                | `#FFFFFF` | `Brand.white`              | —                                                                          |

<!-- tokens:end brand -->

The keyboard's semantic colours — what a Figma component binds to. In Swift
the keys read the chosen theme's palette at run time; these are the design
theme's (ink) values, and the app's catalog colours.

<!-- tokens:begin keyboard -->

| Token                   | Value                                      | Swift                         | Use                                                                      |
| ----------------------- | ------------------------------------------ | ----------------------------- | ------------------------------------------------------------------------ |
| `app/accent-dark`       | `#67AD82` (`brand.green/400`)              | `Keyboard.appAccentDark`      | the catalog's AccentColor in dark                                        |
| `app/accent-light`      | `#01762F` (`brand.green/700`)              | `Keyboard.appAccentLight`     | the catalog's AccentColor in light                                       |
| `app/card-border-dark`  | `#3A362F` (`brand.ink/600`)                | `Keyboard.appCardBorderDark`  | the catalog's CardBorder in dark                                         |
| `app/card-border-light` | `#C7C3B2` (`brand.paper/400`)              | `Keyboard.appCardBorderLight` | the catalog's CardBorder in light                                        |
| `app/card-fill-dark`    | `#26231E` (`brand.ink/800`)                | `Keyboard.appCardFillDark`    | the catalog's CardFill in dark                                           |
| `app/card-fill-light`   | `#F5F3EB` (`brand.paper/tint`)             | `Keyboard.appCardFillLight`   | the catalog's CardFill in light                                          |
| `kb/cancel`             | `#E67F36` (`brand.orange`)                 | `Keyboard.kbCancel`           | the panel's cancel ×                                                     |
| `kb/field`              | `#33302A` (`themes.dark/field`)            | `Keyboard.kbField`            | the key-term field                                                       |
| `kb/field-border`       | `#3A362F` (`themes.dark/field-border`)     | `Keyboard.kbFieldBorder`      | the field's hairline                                                     |
| `kb/full-access-note`   | `#E67F36` (`brand.orange`)                 | `Keyboard.kbFullAccessNote`   | the one line of words the keyboard ever shows                            |
| `kb/key`                | `#33302A` (`themes.dark/key`)              | `Keyboard.kbKey`              | an ordinary key                                                          |
| `kb/key-modifier`       | `#26231E` (`themes.dark/key-modifier`)     | `Keyboard.kbKeyModifier`      | shift, delete, globe, return, 123, cancel                                |
| `kb/legend`             | `#F5F3EB` (`themes.dark/legend`)           | `Keyboard.kbLegend`           | key legends and bare glyphs                                              |
| `kb/legend-secondary`   | `#A5A4A2` (`themes.dark/legend-secondary`) | `Keyboard.kbLegendSecondary`  | the mono word labels (123, ABC, return, space) and the + at rest         |
| `kb/notice-error`       | `#E67F36` (`brand.orange`)                 | `Keyboard.kbNoticeError`      | the solid ring and glyph for an error                                    |
| `kb/notice-ok`          | `#67AD82` (`brand.green/400`)              | `Keyboard.kbNoticeOk`         | the solid ring for pasted and copied                                     |
| `kb/orb-ring-end`       | `#FFFFFF` (`brand.white`)                  | `Keyboard.kbOrbRingEnd`       | the sweeping ring's gradient, bottom-trailing                            |
| `kb/orb-ring-start`     | `#01762F` (`brand.green/700`)              | `Keyboard.kbOrbRingStart`     | the sweeping ring's gradient, top-leading                                |
| `kb/popup`              | `#33302A` (`themes.dark/popup`)            | `Keyboard.kbPopup`            | the letter pop-up                                                        |
| `kb/signal`             | `#67AD82` (`themes.dark/signal`)           | `Keyboard.kbSignal`           | the wave, the caret, the saved check                                     |
| `kb/surface`            | `#1D1B16` (`themes.dark/surface`)          | `Keyboard.kbSurface`          | the design face's surface (Figma binds to kb/*; Swift reads the palette) |

<!-- tokens:end keyboard -->

Gradients:

<!-- tokens:begin gradients -->

- `orb` (`Gradients.orb`, bottom → top): `#D7D3F4` at 0, `#B0A7E9` at 0.0673, `#67AD82` at 0.1442, `#01762F` at 0.3029, `#3923C7` at 0.5962, `#887BDD` at 0.75, `#D7D3F4` at 0.8942, `#FFFFFF` at 1 — the Mac orb's fill, the design's own stops (App elements/Recording.svg), swept bottom to top
- `orb-ring` (`Gradients.orbRing`, topLeading → bottomTrailing): `#01762F` at 0, `#FFFFFF` at 1 — the ring round the orb: green into white, corner to corner; spun while something is happening

<!-- tokens:end gradients -->

The default theme follows the host app's light or dark appearance, as the
iPhone keyboard does; Blurt's own themes are **fixed**, whatever the host
app's appearance, for the reason the Mac pill is: the keyboard floats over
whichever app the user is typing in and must read the same over a white Notes
page and a black Messages thread. Nothing on it uses `accent`.

## Type

System font throughout (SF Pro; the Figma file must have it installed, never
Inter). Sizes are fixed points, not Dynamic Type, as the system keyboard's are.

<!-- tokens:begin type -->

| Token              | Value      | Swift                        | Use                                                                         |
| ------------------ | ---------- | ---------------------------- | --------------------------------------------------------------------------- |
| `ratio/orb-glyph`  | `0.34`     | `Typography.ratioOrbGlyph`   | the clipboard and exclamation glyphs, as a fraction of the orb              |
| `size/body`        | `16`       | `Typography.sizeBody`        | the app's body text                                                         |
| `size/caption`     | `14`       | `Typography.sizeCaption`     | the app's small text                                                        |
| `size/cta`         | `14`       | `Typography.sizeCta`         | a mono button label in the app (E2)                                         |
| `size/eyebrow`     | `12`       | `Typography.sizeEyebrow`     | a mono eyebrow in the app (E1)                                              |
| `size/glyph`       | `17`       | `Typography.sizeGlyph`       | the +, × and ✓                                                              |
| `size/label`       | `12`       | `Typography.sizeLabel`       | the mono word labels on keys: 123, ABC, #+=, space, the return label        |
| `size/legend`      | `16`       | `Typography.sizeLegend`      | every other key                                                             |
| `size/letter`      | `24`       | `Typography.sizeLetter`      | letter keys: the iPhone's (estimated from the l glyph, apple-geometry.json) |
| `size/popup`       | `32`       | `Typography.sizePopup`       | the letter pop-up                                                           |
| `size/term`        | `17`       | `Typography.sizeTerm`        | the key-term field                                                          |
| `size/title`       | `34`       | `Typography.sizeTitle`       | the app's serif headline                                                    |
| `tracking/cta`     | `1.4`      | `Typography.trackingCta`     | uppercase mono at 14: the brand's E2 tracking                               |
| `tracking/eyebrow` | `1.2`      | `Typography.trackingEyebrow` | uppercase mono at 12: the brand's E1 tracking                               |
| `weight/glyph`     | `medium`   | `Typography.weightGlyph`     | —                                                                           |
| `weight/label`     | `medium`   | `Typography.weightLabel`     | —                                                                           |
| `weight/legend`    | `medium`   | `Typography.weightLegend`    | —                                                                           |
| `weight/letter`    | `regular`  | `Typography.weightLetter`    | —                                                                           |
| `weight/orb-glyph` | `semibold` | `Typography.weightOrbGlyph`  | —                                                                           |
| `weight/popup`     | `regular`  | `Typography.weightPopup`     | —                                                                           |
| `weight/term`      | `regular`  | `Typography.weightTerm`      | —                                                                           |

<!-- tokens:end type -->

## Fonts (`Design/fonts/`, `DesignTokens.Fonts`)

The brand's three faces, bundled in both targets and named by PostScript name
(what `Font.custom` takes). Letter keys stay in SF Pro; everything that is a
word label on the keyboard, and the app's eyebrows and buttons, is Modern
Gothic Mono in uppercase; the app's headlines are Oceanic Text, its body
UN 11ST.

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

## Metrics and motion

Every size, gap, radius, opacity and duration the keyboard's views use. The
heights in `KeyboardLayout.height` are derived from these (slim = 2 ×
`margin/vertical` + `voicebar/height`; full adds 4 × `row/gap` + 4 ×
`key/height`; the panel's is chosen), and `LayoutArithmeticTests` pins the
derivation.

<!-- tokens:begin metrics -->

| Token                         | Points    | Swift                              | Use                                                                                            |
| ----------------------------- | --------- | ---------------------------------- | ---------------------------------------------------------------------------------------------- |
| `addterm/inset`               | `6`       | `Metrics.addtermInset`             | the + from the panel's corner                                                                  |
| `card/border`                 | `1`       | `Metrics.cardBorder`               | the card's hairline                                                                            |
| `card/radius`                 | `16`      | `Metrics.cardRadius`               | the app's cards                                                                                |
| `caret/height`                | `20`      | `Metrics.caretHeight`              | —                                                                                              |
| `caret/lead`                  | `1`       | `Metrics.caretLead`                | the caret's gap from the text                                                                  |
| `caret/radius`                | `1`       | `Metrics.caretRadius`              | —                                                                                              |
| `caret/width`                 | `2`       | `Metrics.caretWidth`               | —                                                                                              |
| `gesture/swipe-min`           | `24`      | `Metrics.gestureSwipeMin`          | the carousel gesture's minimum distance                                                        |
| `glyph/hit`                   | `32`      | `Metrics.glyphHit`                 | the +, × and ✓ touch targets                                                                   |
| `key/abc-width-402`           | `43.333`  | `Metrics.keyAbcWidth402`           | 123 and the globe at 402 pt: the iPhone's                                                      |
| `key/gap`                     | `6`       | `Metrics.keyGap`                   | between keys, the iPhone's                                                                     |
| `key/height`                  | `43`      | `Metrics.keyHeight`                | every key: the iPhone's cap height (apple-geometry.json)                                       |
| `key/letter-width-402`        | `33.5`    | `Metrics.keyLetterWidth402`        | a letter key at 402 pt: (width − 2 × margin/side − 9 × key/gap) / 10                           |
| `key/min-width`               | `43.333`  | `Metrics.keyMinWidth`              | a key that isn't given a width: the iPhone's 123 key at 402 pt                                 |
| `key/pad`                     | `4`       | `Metrics.keyPad`                   | a legend's side padding on a min-width key                                                     |
| `key/radius`                  | `8`       | `Metrics.keyRadius`                | flat keys, one colour at this corner: the iPhone's (fitted 8.17)                               |
| `key/reference-width`         | `402`     | `Metrics.keyReferenceWidth`        | the width the @402 tokens were measured at (iPhone 18 Pro); widths scale from it               |
| `key/return-width-402`        | `92.667`  | `Metrics.keyReturnWidth402`        | return at 402 pt: two 123 keys and a gap                                                       |
| `key/side-gap`                | `13.667`  | `Metrics.keySideGap`               | shift and delete stand this far from the letters: the iPhone's                                 |
| `key/side-width-402`          | `45.583`  | `Metrics.keySideWidth402`          | shift and delete at 402 pt: what seven letters and the side gaps leave, halved (measured 45.5) |
| `key/space-width-402`         | `191.667` | `Metrics.keySpaceWidth402`         | space at 402 pt beside 123, the globe and return: what is left (measured 191.333)              |
| `layout/full`                 | `270`     | `Metrics.layoutFull`               | margin/vertical + voicebar/height + 4 × key/height + 3 × row/gap + margin/bottom-keys          |
| `layout/panel`                | `216`     | `Metrics.layoutPanel`              | chosen: room for the 96 orb over one key row                                                   |
| `layout/slim`                 | `60`      | `Metrics.layoutSlim`               | 2 × margin/vertical + voicebar/height                                                          |
| `margin/bottom-keys`          | `13`      | `Metrics.marginBottomKeys`         | under a bottom row of keys (the full keyboard, the panel): the iPhone's                        |
| `margin/side`                 | `6.5`     | `Metrics.marginSide`               | at the keyboard's sides: the iPhone's cap margin, (402 − 10 letters − 9 gaps) / 2              |
| `margin/vertical`             | `8`       | `Metrics.marginVertical`           | the keyboard's top, and the slim bar's bottom                                                  |
| `opacity/dim`                 | `0.8`     | `Metrics.opacityDim`               | the orb when Blurt isn't ready                                                                 |
| `opacity/dim-saturation`      | `0.35`    | `Metrics.opacityDimSaturation`     | and its saturation                                                                             |
| `opacity/disabled`            | `0.4`     | `Metrics.opacityDisabled`          | the + without Full Access                                                                      |
| `opacity/grain`               | `0.5`     | `Metrics.opacityGrain`             | —                                                                                              |
| `opacity/home-dim-saturation` | `0.45`    | `Metrics.opacityHomeDimSaturation` | the home hero's saturation when not listening                                                  |
| `opacity/legend`              | `1`       | `Metrics.opacityLegend`            | key legends over the cap; below 1 they sit back                                                |
| `opacity/legend-muted`        | `0.5`     | `Metrics.opacityLegendMuted`       | the + at rest                                                                                  |
| `opacity/orb-light`           | `0.3`     | `Metrics.opacityOrbLight`          | —                                                                                              |
| `opacity/placeholder`         | `0.4`     | `Metrics.opacityPlaceholder`       | the field's placeholder                                                                        |
| `opacity/popup-shadow`        | `0.12`    | `Metrics.opacityPopupShadow`       | —                                                                                              |
| `opacity/press-brighten`      | `0.15`    | `Metrics.opacityPressBrighten`     | a key lightens this much while pressed                                                         |
| `opacity/surface-grain`       | `0.14`    | `Metrics.opacitySurfaceGrain`      | film grain over the whole keyboard surface: matte, the brand's texture                         |
| `opacity/surface-vignette`    | `0`       | `Metrics.opacitySurfaceVignette`   | a soft darkening toward the surface's edges; 0 is none                                         |
| `opacity/term-cancel`         | `0.7`     | `Metrics.opacityTermCancel`        | the field's ×                                                                                  |
| `orb/bar`                     | `40`      | `Metrics.orbBar`                   | the orb in the voice bar                                                                       |
| `orb/dissipate-blur`          | `0.16`    | `Metrics.orbDissipateBlur`         | and blurs to this fraction of its size                                                         |
| `orb/dissipate-scale`         | `1.25`    | `Metrics.orbDissipateScale`        | the orb swells to this while dissipating                                                       |
| `orb/home`                    | `112`     | `Metrics.orbHome`                  | the orb on the home screen                                                                     |
| `orb/light-reach`             | `0.9`     | `Metrics.orbLightReach`            | the soft light's reach, as a fraction of the orb (was a fixed 110 pt, flat on a 40 pt orb)     |
| `orb/light-x`                 | `0.3`     | `Metrics.orbLightX`                | the soft light's centre, as a fraction of the orb                                              |
| `orb/light-y`                 | `0.22`    | `Metrics.orbLightY`                | —                                                                                              |
| `orb/panel`                   | `96`      | `Metrics.orbPanel`                 | the orb in the panel                                                                           |
| `panel/spacing`               | `12`      | `Metrics.panelSpacing`             | between the panel's orb and its key row                                                        |
| `picker/preview-width`        | `393`     | `Metrics.pickerPreviewWidth`       | the theme card draws the keyboard at this width                                                |
| `picker/radius`               | `10`      | `Metrics.pickerRadius`             | the theme card's preview corners                                                               |
| `picker/scale`                | `0.42`    | `Metrics.pickerScale`              | then scales it to fit two across                                                               |
| `popup/extra-width`           | `18`      | `Metrics.popupExtraWidth`          | the letter pop-up is the key width plus this                                                   |
| `popup/height`                | `56`      | `Metrics.popupHeight`              | —                                                                                              |
| `popup/offset`                | `58`      | `Metrics.popupOffset`              | the pop-up sits this far above the key                                                         |
| `popup/radius`                | `10`      | `Metrics.popupRadius`              | —                                                                                              |
| `popup/shadow-radius`         | `8`       | `Metrics.popupShadowRadius`        | the one thing that floats                                                                      |
| `popup/shadow-y`              | `2`       | `Metrics.popupShadowY`             | —                                                                                              |
| `press/scale`                 | `0.94`    | `Metrics.pressScale`               | the orb while pressed                                                                          |
| `ring/active`                 | `2`       | `Metrics.ringActive`               | the ring while working or noticing; the home ring                                              |
| `ring/still`                  | `1`       | `Metrics.ringStill`                | the ring at rest                                                                               |
| `row/gap`                     | `11`      | `Metrics.rowGap`                   | between rows, the iPhone's                                                                     |
| `slim/spacing`                | `8`       | `Metrics.slimSpacing`              | between the slim bar's keys                                                                    |
| `surface/vignette-end`        | `0.75`    | `Metrics.surfaceVignetteEnd`       | where it is full                                                                               |
| `surface/vignette-start`      | `0.3`     | `Metrics.surfaceVignetteStart`     | where the vignette begins, as a fraction of the keyboard's width                               |
| `term/gap`                    | `8`       | `Metrics.termGap`                  | × · field · ✓                                                                                  |
| `term/height`                 | `36`      | `Metrics.termHeight`               | the key-term field's capsule                                                                   |
| `term/inset`                  | `2`       | `Metrics.termInset`                | the field row's side inset                                                                     |
| `term/pad`                    | `14`      | `Metrics.termPad`                  | the field's side padding                                                                       |
| `voicebar/addterm-clearance`  | `12`      | `Metrics.voicebarAddtermClearance` | the wave stays this clear of the + at the trailing edge                                        |
| `voicebar/height`             | `44`      | `Metrics.voicebarHeight`           | the voice row, where the system puts its suggestion bar                                        |
| `voicebar/note-gap`           | `10`      | `Metrics.voicebarNoteGap`          | between the orb and the Full Access note                                                       |
| `wave/bar`                    | `2`       | `Metrics.waveBar`                  | a wave bar's width                                                                             |
| `wave/bar-height`             | `24`      | `Metrics.waveBarHeight`            | —                                                                                              |
| `wave/bar-width`              | `240`     | `Metrics.waveBarWidth`             | the wave in the voice bar, at most                                                             |
| `wave/gap`                    | `2`       | `Metrics.waveGap`                  | between wave bars                                                                              |
| `wave/home-height`            | `44`      | `Metrics.waveHomeHeight`           | —                                                                                              |
| `wave/home-width`             | `280`     | `Metrics.waveHomeWidth`            | —                                                                                              |
| `wave/liquid`                 | `0`       | `Metrics.waveLiquid`               | 1 draws the wave as one liquid shape through the bar heights instead of the bars themselves    |
| `wave/panel-height`           | `40`      | `Metrics.wavePanelHeight`          | —                                                                                              |
| `wave/panel-width`            | `300`     | `Metrics.wavePanelWidth`           | —                                                                                              |
| `wordmark/height`             | `22`      | `Metrics.wordmarkHeight`           | —                                                                                              |

<!-- tokens:end metrics -->

Motion, in seconds. Nothing springs or snaps; only the press answers at once.

<!-- tokens:begin motion -->

| Token            | Value           | Swift                  | Use                                                           |
| ---------------- | --------------- | ---------------------- | ------------------------------------------------------------- |
| `caret`          | `0.5`           | `Motion.caret`         | the caret's blink                                             |
| `colour`         | `0.2`           | `Motion.colour`        | a colour or fill changing state: the brand's transition       |
| `drop`           | `2.4`           | `Motion.drop`          | the violet drop is gone by                                    |
| `drop-hold`      | `0.9`           | `Motion.dropHold`      | and held to                                                   |
| `drop-rise`      | `0.5`           | `Motion.dropRise`      | the drop is up in                                             |
| `drop-spread`    | `1`             | `Motion.dropSpread`    | the bloom reaches its full spread in                          |
| `ease/signature` | `0.22,1,0.36,1` | `Motion.easeSignature` | the house curve for everything that moves; nothing springs    |
| `flip`           | `0.25`          | `Motion.flip`          | the panel's carousel                                          |
| `height-change`  | `0.25`          | `Motion.heightChange`  | the keyboard resizing                                         |
| `key-press`      | `0.08`          | `Motion.keyPress`      | a key lighting                                                |
| `landing`        | `0.6`           | `Motion.landing`       | the glint when the words land                                 |
| `mood`           | `0.8`           | `Motion.mood`          | the orb's colour moving between moods                         |
| `press`          | `0.1`           | `Motion.press`         | the orb's press; the one thing that answers at once           |
| `ring-period`    | `1.6`           | `Motion.ringPeriod`    | one turn of the ring, the Mac's cadence                       |
| `state-fade`     | `0.5`           | `Motion.stateFade`     | every other change on the key: the ring, a glyph, the dimming |
| `term-swap`      | `0.4`           | `Motion.termSwap`      | the voice bar becoming the field                              |
| `wave-fade`      | `0.7`           | `Motion.waveFade`      | the orb and the wave crossing, either way                     |

<!-- tokens:end motion -->

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
| press delay on the orb | 90 ms                                                                                          | a swipe that starts on the orb never starts a dictation it must then cancel                              |
| tap travel             | 12 pt (keys), 24 pt (orb), swipe ≥ 48 pt horizontal and 1.5× the vertical                      | the carousel's swipe never types or dictates                                                             |
| level publish          | every 80 ms while recording                                                                    | the orb's meter, off the capture path's back                                                             |
| lexicon refresh        | hourly                                                                                         | thousands of contacts on a keyboard memory budget                                                        |
| height change          | 0.25 s; constraint priority 999                                                                | iOS honours a keyboard's height at just under required                                                   |
| the visual numbers     | see Metrics and motion above                                                                   | generated from `Design/tokens.json`; the views carry no literals                                         |
| term packs             | ≤ 64 KB, ≤ 100 terms, ≤ 80 characters each                                                     | the request's cap; unbounded input from a stranger                                                       |

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
