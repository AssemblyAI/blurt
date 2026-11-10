# Blurt for iPhone — design

The iPhone app is Blurt's brand on a phone: Cam Neri's "warped futurism" as
it appears on assemblyai.com/blurt — an ink ground under film grain, a warm
paper one in the light, serif headlines, uppercase mono labels, green as the
one signal, rectangular corners. The keyboard is Apple's: KeyboardKit's free
core (`KeyboardView`; 11.1.6, the app's one remote package — `README.md` ›
Dependencies) draws the iPhone's own keyboard in the iPhone's own colours
and owns typing, shift and caps lock, the symbol pages and the number pad,
delete and its repeat, the callouts, the space bar's cursor drag and the
input clicks. Blurt adds two things to it and nothing else — the mic key in
the bottom row and the bar above the keys — so nothing is unfamiliar under
the fingers and nothing of the keyboard itself is Blurt's to get wrong.
Every number and colour Blurt's own parts draw with is a token, every rule
has a test, and the keyboard is measured against Apple's rather than
assumed.

Sources of truth: the brand design system
(`https://www.assemblyai.com/brand-design-system/assemblyai-brand-design-system.md`)
and the Blurt landing page for the app's look; `Design/apple-geometry-<profile>.json`
for the keys — Apple's keyboard as the probe measured it, the oracle the
parity run reads Blurt's keyboard against; `Design/tokens.json` for every
value the app's screens and the keyboard's own parts draw with. From the
tokens, `scripts/design-tokens.swift` writes `BlurtDesign/DesignTokens.swift`
(what the views read), the tables in this file marked `tokens:begin` /
`tokens:end`, and the app's asset-catalog colour sets. Edit the JSON, run
`scripts/design-sync.sh`, commit; `check.sh` runs `design-sync.sh --check`
and fails on drift or on a design literal in a view (`// literal-ok:
<reason>` for a genuine derivation).

## Reproducing it

The keyboard is captured as it runs — the extension in its own process, over
a bare text field in the app (`-BlurtProbeField light|dark`, debug builds
only, `BlurtiOS/Sources/KeyboardProbeView.swift`) — never from a preview,
since a preview cannot vouch for what the host does to an extension. The
`BlurtiOSProbe` UI tests drive it (XCTest, the one allowed use of it; its
own scheme, never in the app's test run or the periphery scan), and four
scripts run them:

```bash
scripts/keyboard-parity.sh [--out .build/design/parity]
    # Apple's keyboard and Blurt's on one simulator, every key's frame on both faces; prints each key's
    # dx/dy/dw/dh against Apple's, the rows' edges and the keyboard's bottom, and fails past
    # BLURT_PARITY_TOLERANCE (0.5 pt); a screenshot of each keyboard beside the JSON, for what a frame
    # cannot say (the caps' colour, the radius, the legend)
scripts/apple-geometry.sh [--profile glass-402|classic-390|classic-375]
    # Apple's keyboard alone → Design/apple-geometry-<profile>.json, the simulator's device, os, runtime
    # and scale recorded: the oracle; BLURT_SIM_RUNTIME=18.6 BLURT_SIM_DEVICE="iPhone 16e (18.6)" for a
    # classic profile
scripts/ios-keyboard-shot.sh [--face light|dark] [--out FILE.png]
    # one screenshot of the real keyboard over the field
scripts/ios-keyboard-flows.sh [--face light|dark] [--out DIR]
    # the keyboard used, with the app listening: the mic between space and return, the + in the bar,
    # letters typing, a word highlighted and added, the term field, a dictation started and stopped,
    # the globe away and back, put away and brought back — one FLOW-OK / FLOW-FAIL line and a
    # screenshot per step, a sheet per face, under .build/design/flows/<face>/
scripts/design-sync.sh [--check]   # tokens.json → DesignTokens.swift, these tables, the colour sets
```

Blurt must be enabled as a keyboard on the simulator once by hand (Settings
→ General → Keyboard → Keyboards → Add New Keyboard), and Device Hub's
"Always simulate hardware keyboard" must be off, or no keyboard ever comes
up. The capture device is the iPhone 18 Pro (402 pt, 3×), pinned in
`scripts/ios-sim.sh`. The classic generation's leg runs on an iOS 18
simulator (`BLURT_SIM_RUNTIME=18.6 BLURT_SIM_DEVICE="iPhone 16e (18.6)"`
before any of the four; `scripts/ios-lib.sh` keeps the pick to that runtime
and reads the device type's scale), which Xcode 27's downloader has refused
so far (`xcodes runtimes install "iOS 18.6"`: "iOS 22G86 is not available
for download", 18.5 and 18.4 the same), so that leg has not run yet.

The app's own screens render from a launch argument, so a screenshot never
depends on tapping through: `-BlurtSettings`, `-BlurtKeepOpen`
(`-BlurtGalleryStill` parks its motion) and `-BlurtTypingTest` (The app's
screens, below):

```bash
BLURT_LAUNCH_ARGS="-BlurtSettings" scripts/ios-sim.sh --screenshot settings.png
BLURT_LAUNCH_ARGS="-BlurtKeepOpen -BlurtGalleryStill" scripts/ios-sim.sh --screenshot keep-open.png
```

## The two faces

The keyboard follows the field it is typing into, as the iPhone's does:
KeyboardKit reads the host's appearance into its context (`colorScheme`)
and draws Apple's light keyboard or Apple's dark one — the keys, their
legends, the callouts and the bar all in KeyboardKit's own colours
(`Color.keyboardButtonBackground`, `keyboardButtonForeground`,
`keyboardDarkButtonForeground` and `keyboardButtonShadow`, each `for:` the
scheme). Blurt paints none of it. Two brand colours stay on the keyboard,
each in the scheme's own version (`BlurtTint`): the **signal** green — the
mic while recording, the caret, a saved term's check, the chip's + — and the
**notice** orange — the status line and a failure. They are the whole of
the brand's two faces now, one row each; `DesignTokensTests` pins them to
the brand (green as the signal, orange as the notice):

<!-- tokens:begin themes -->

| Face    | Signal    | Notice    |
| ------- | --------- | --------- |
| `light` | `#01762F` | `#E67F36` |
| `dark`  | `#67AD82` | `#E67F36` |

<!-- tokens:end themes -->

**The face is read once the host has it.** The host's traits arrive on their
own schedule: the controller tells the model in `viewIsAppearing` (after
`viewWillAppear`), never from a trait-change registration — that callback
runs inside the host's layout pass, and a model change made there left the
mic's drawing uncommitted in Messages (nothing drew, every time; the probe
app never fires it). The keyboard's height and surface are KeyboardKit's;
whether the host's own material matches the keys it draws is what the two
screenshots the parity run leaves beside its JSON are for, since a frame
cannot say. `scripts/ios-keyboard-shot.sh` and the `MessagesKeyboardShot`
UI test capture the real keyboard in the app and in Messages.

The app's screens follow the phone's appearance through the asset catalog's
colour sets (generated from the `keyboard.app/*` tokens): `Page`, `Text`,
`Muted`, `CardFill`, `CardBorder`, `AccentColor`, `CTA`, `CTAText`.

## Apple's geometry, measured

KeyboardKit draws the keys, so no token of Blurt's decides a cap's width on
its own; what Blurt decides is that the result is Apple's, and that is
measured, never assumed. KeyboardKit's layout configuration
(`KeyboardLayoutConfiguration`, set beside the layout in
`BlurtKeyboard/Sources/Shared/KeyboardLayout+Blurt.swift`) carries the row
height, the keys' insets, the corner radius and the keyboard's edges, and
`scripts/keyboard-parity.sh` checks what KeyboardKit draws from them against
Apple's keyboard on the same simulator. The numbers themselves live in the
geometry JSON and in The two processes, not in this prose.

Two probes share one reader (`BlurtiOSProbe/KeyboardMeasure.swift`): the app
launches on `-BlurtProbeField light|dark`, a bare text field takes a
keyboard, and the test reads every key's frame on both faces and attaches
the record beside a screenshot. `AppleKeyboardProbe` reads the system
keyboard (XCUITest's one `Keyboard` element); `BlurtKeyboardProbe` reads
Blurt's the same way — a custom keyboard has no such element, only its
controls, so the keys are the keys and buttons in the bottom of the window
(KeyboardKit's keys carry the keyboard-key trait; the host's own globe and
dictation button are left out) and the keyboard's frame is their union.
`scripts/keyboard-parity.sh` runs both and prints each key's dx, dy, dw and
dh against Apple's, matched under the two keyboards' names (`shift` for `⇧`,
`more` for `123`, and so on), the rows' edges and the keyboard's bottom,
and fails on anything over `BLURT_PARITY_TOLERANCE` (0.5 pt). The oracle is
Apple's keyboard on that simulator, so a new iOS is measured, not assumed.

`scripts/apple-geometry.sh` runs the Apple probe alone and writes what it
found as `Design/apple-geometry-<profile>.json`, one file per profile with
the simulator's device, os, runtime and scale in it. XCUITest reports touch
cells, which tile a row with no gaps, so the caps themselves — widths, gaps,
height, the corner radius fitted to the top-left inset, the band above the
keys and the margin under them — are read off the screenshot by
`scripts/design-diff.swift measure`. The files are the measurement's record
and the numbers the layout configuration answers to; `AppleGeometryTests`
(`BlurtiOSTests/KeyboardParityTests.swift`) checks that each parses at the
width its name says with every number the probe reads, and that it says
whether a phone measured it:

| Profile   | Simulator                                                                                             | State                                                                                                                                                                                                                                                                                                                                                                                                                         |
| --------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `glass`   | iOS 26 and later: the host's keyboard container around the keyboard (`apple-geometry-glass-402.json`) | measured on the iPhone 18 Pro, iOS 27, at 402 pt; the dark face identical                                                                                                                                                                                                                                                                                                                                                     |
| `classic` | iOS 18 through 25 (`apple-geometry-classic-390.json`, `-375.json`)                                    | **unmeasured** (`unmeasured: true` in the files: the plan's numbers, never Apple's) until an iOS 18 runtime installs — Xcode 27's downloader refuses every iOS 18.x runtime; `scripts/apple-geometry.sh --profile classic-390` on an "iPhone 16e (18.6)" (3×, Face ID) and `classic-375` on an "iPhone SE (3rd generation) (18.6)" (2×, a globe in the keyboard) replace them, and then the parity run on the same simulators |

## The mic's place

Apple's own dictation mic on a Face ID phone is not in the keyboard: it sits
with the globe in the host's bar under the keyboard (58 pt on the 18 Pro,
`systemBarBelow` in the glass JSON), which iOS draws and no extension can
draw into. So the mic takes the small key's place on the other side of
space, at the 123 key's own size, and every other cap keeps Apple's width
(`KeyboardLayout.blurt`, `KeyboardAction.blurtMic`): **123 · space · mic ·
return**, or **123 · globe · space · mic · return** on a phone that puts the
globe in the row (`needsInputModeSwitchKey`) — five keys, as Apple's own row
has there. The same row on the symbol pages, with ABC leading it; never on
the number pad, which KeyboardKit draws from no rows at all
(`Keyboard.NumberPad`) and Apple's has no mic on. `BlurtLayoutTests` pins the
row against `KeyboardLayout.standard` on every page, with and without the
globe: the mic after space, nothing else moved, the mic at the small key's
size, and one mic however often the layout is built.
`scripts/ios-keyboard-flows.sh` checks the real one: the mic between space
and return on the row's centre line, the + in the bar above the keys at its
trailing end.

Apple's row has one place for the mic, so there is no mic-alignment setting
and no one-hand layout; Settings keeps Hands-free for the keyboard and
nothing else.

## Keys

KeyboardKit's, as Apple draws them: the caps, their colour and corner, the
press, the callouts, shift and caps lock, delete and its repeat, 123 / #+= /
ABC turning the pages, the space bar's hold moving the cursor
(`spacebarLongPressBehavior` = `.moveInputCursor`, after `motion/space-hold`
0.25 s rather than KeyboardKit's half second) and the input clicks.
The case is KeyboardKit's rule too — uppercase at a sentence's start in a
field that capitalizes sentences, lowercase after the first letter, shift
for one letter — and the layout follows it: `BlurtKeyboardView` observes
the context and rebuilds `KeyboardLayout.blurt` on every change, because
a layout handed over once kept the uppercase letters the keyboard came up
with and typed them (the flows' case check, on a field launched with
`-BlurtProbeSentences`).
Blurt styles one key: the mic's cap wears the 123 key's style
(`keyboardButtonStyle` in `BlurtKeyboardView` answers `.blurtMic` with the
standard style for `.keyboardType(.numeric)`), the system key Apple's own
in-row mic sits on, so it reads as one of the row; the press on it is
KeyboardKit's too, and reaches `BlurtActionHandler` (The mic key, below).
The emoji switcher is off (`isEmojiSwitcherEnabled` = false: there is no
emoji keyboard on the free core) and autocorrect is off
(`isAutocorrectEnabled` = false: a Pro feature, not wired).

The bar's keys are Blurt's, and they are not caps: the +, the × and the ✓
are one glyph key (`GlyphKey`) — a `size/glyph` SF Symbol in a `glyph/hit`
square (44 pt, the HIG's), lightening `opacity/press-brighten` while the
finger is on it (`KeyPressStyle`; a gesture state, so a touch the system
takes away unlights it too), in the legend colour of Apple's keyboard
(`BlurtTint.legend`). The chip and the term field take a key's own cap
colour and its hairline (`BlurtTint.field`, `BlurtTint.edge`) at the brand's
input corner (`term/radius`). The chip acts on release and only under
`KeyboardInteraction.tapTravel` (12 pt) of travel, so a swipe that started
on it adds nothing (tested).

Type on the keys is KeyboardKit's: Apple's letters and labels at Apple's
sizes. Blurt's own text — the status line (`size/line`), the term and the
chip (`size/term`) — is the system face at fixed point sizes, as the system
keyboard's is; no Dynamic Type:

<!-- tokens:begin type -->

| Token                | Value     | Swift                         | Use                                                                      |
| -------------------- | --------- | ----------------------------- | ------------------------------------------------------------------------ |
| `size/body`          | `16`      | `Typography.sizeBody`         | the app's body text                                                      |
| `size/caption`       | `14`      | `Typography.sizeCaption`      | the app's small text                                                     |
| `size/cta`           | `14`      | `Typography.sizeCta`          | a mono button label in the app (E2)                                      |
| `size/eyebrow`       | `12`      | `Typography.sizeEyebrow`      | a mono eyebrow in the app (E1)                                           |
| `size/glyph`         | `17`      | `Typography.sizeGlyph`        | the +, × and ✓                                                           |
| `size/line`          | `12`      | `Typography.sizeLine`         | the one line of words in the bar (the status line, the Full Access note) |
| `size/pill-glyph`    | `10`      | `Typography.sizePillGlyph`    | the × on a key-term pill                                                 |
| `size/remove-glyph`  | `12`      | `Typography.sizeRemoveGlyph`  | the × on a text-shortcut row                                             |
| `size/stat-l`        | `23`      | `Typography.sizeStatL`        | the next size down when the stats would not fit                          |
| `size/stat-m`        | `20`      | `Typography.sizeStatM`        | and the next                                                             |
| `size/stat-s`        | `18`      | `Typography.sizeStatS`        | the smallest a stat is drawn                                             |
| `size/stat-xl`       | `26`      | `Typography.sizeStatXl`       | a stat's serif number, at the largest size that fits                     |
| `size/tab-icon`      | `18`      | `Typography.sizeTabIcon`      | a tab's icon                                                             |
| `size/tab-label`     | `11`      | `Typography.sizeTabLabel`     | a tab's mono label                                                       |
| `size/term`          | `17`      | `Typography.sizeTerm`         | the key-term field                                                       |
| `size/title`         | `34`      | `Typography.sizeTitle`        | the app's serif headline                                                 |
| `size/typing-clock`  | `64`      | `Typography.sizeTypingClock`  | the typing test's countdown                                              |
| `size/typing-field`  | `22`      | `Typography.sizeTypingField`  | what you've typed                                                        |
| `size/typing-live`   | `28`      | `Typography.sizeTypingLive`   | its live words per minute                                                |
| `size/typing-rank`   | `28`      | `Typography.sizeTypingRank`   | the result's rank, in the serif                                          |
| `size/typing-result` | `96`      | `Typography.sizeTypingResult` | the result's words per minute                                            |
| `size/typing-unit`   | `16`      | `Typography.sizeTypingUnit`   | the result's WPM                                                         |
| `size/typing-words`  | `24`      | `Typography.sizeTypingWords`  | the words to type                                                        |
| `tracking/cta`       | `1.4`     | `Typography.trackingCta`      | uppercase mono at 14: the brand's E2 tracking                            |
| `tracking/eyebrow`   | `1.2`     | `Typography.trackingEyebrow`  | uppercase mono at 12: the brand's E1 tracking                            |
| `weight/glyph`       | `medium`  | `Typography.weightGlyph`      | —                                                                        |
| `weight/term`        | `regular` | `Typography.weightTerm`       | —                                                                        |

<!-- tokens:end type -->

No font is bundled: every face is the system's, reached only through
`BlurtType` by role — `mono` (the system's monospaced design) for eyebrows
and CTAs, `heading` (its serif design) for the app's headlines, `body` (the
default face) for body text — so a call site names the role and the faces
can change in one place. The keys take no role: their type is KeyboardKit's.

## The mic key

The mic key is the one part of the keyboard that says what is happening, and
it says it the way Apple's dictation key would: a plain glyph (`MicKey`,
drawn as the key's content; the cap, the press and the gestures are
KeyboardKit's, as for every key). The glyph is an SF Symbol and the colour
is the state's:

| State                   | Glyph                                                                                                                               | Colour                  | Haptic                       |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ----------------------- | ---------------------------- |
| no Full Access          | `mic.fill`, dimmed to `opacity/off`; the bar is the note "Allow Full Access in Settings", and a tap on either opens Blurt's setup   | the key's legend colour | —                            |
| app not listening       | `mic.fill`, dimmed; a tap opens Blurt, and the line in the bar says why                                                             | the legend colour       | —                            |
| idle                    | `mic.fill`                                                                                                                          | the legend colour       | —                            |
| connecting / processing | `mic.fill`; the line says "Still transcribing…" after 3 s of processing                                                             | the legend colour       | — / light impact on the stop |
| recording               | `waveform`, its bars following the level the app publishes (the symbol's `variableValue`)                                           | signal green            | medium impact                |
| pasted                  | `mic.fill` for 1.2 s                                                                                                                | signal green            | success                      |
| copied                  | `doc.on.clipboard` for 2 s                                                                                                          | signal green            | success                      |
| error                   | `exclamationmark` for 2 s, whether or not Blurt is ready (a failure is often why it isn't); the reason in the line and on VoiceOver | notice orange           | error                        |

Every change fades over `state-fade` (the glyph through
`contentTransition(.symbolEffect(.replace))`); nothing snaps. `VoiceState`
(`BlurtiOSCore`) decides all of it — ready, recording, the tone, the glyph,
the dimming — from the phase the app published, so each decision is a tested
value and never a branch in the view (`VoiceStateTests`).

The press is KeyboardKit's gesture on the key, routed by `BlurtActionHandler`
(a `StandardKeyboardActionHandler`): finger down is `KeyboardModel.micDown`
and finger up — on the key or off it — `micUp`. The key is a signal, never a
hold (`PressHandshake`): the first finger down sends the press and the
dictation starts; the next finger down sends the stop, the moment it lands,
and the words are on their way; the lift sends nothing, except the hop that
opens Blurt after a refused press. There is no push-to-talk on the phone and
no waiting for the finger to come up. The key clicks on the press as every
key does; the dictation's own haptics are in the table. A second press made
while the first is still unanswered (the engine drops one before it records)
is held and sent the moment the dictation has its id, so a quick double tap
over a slow mic still stops. Every phase the app publishes carries the id of
the keyboard command it last took (`PhaseSnapshot.command`), and the
keyboard settles its gate only for a phase that answers the press it is
waiting on — the previous dictation's notice landing a moment after a new
press used to reset the gate and turn the next tap into a second press
instead of the stop. An in-flight phase with the app gone (killed, the mic
taken) reads as idle, a notice is never replayed once its dwell ran out, and
a keyboard that comes up without Full Access starts from idle with the gate
reset. `KeyboardModelFuzzTests` drives the model through ten thousand random
event sequences and checks these invariants after every one.

Delete right after a dictation landed takes all of it back, the one-tap undo
(`KeyboardModel.undoLastInsertion`, routed by the handler on delete's press):
only in the field the words went into, while the caret still sits at their
end with nothing highlighted; anywhere else the delete is an ordinary one.
The handler tells the model when a key edited the host's text
(`hostEdited`), so the undo and the chip follow the text at once rather
than on the host's next notification.

## The bar above the keys

Where Apple's keyboard shows its predictions — empty on KeyboardKit's free
core — Blurt puts its own (`BlurtToolbar`, in KeyboardKit's `toolbar`
slot): one of three things, each fading into the next over `term-swap` or
`state-fade`.

- **The status line and the +.** The line at the leading end, the + at the
  trailing end (`AddTermKey`; the chip for a highlighted word takes its
  place — Quick-add key term, below). The line is `VoiceNotice.line`
  (`KeyboardModel.statusLine`): one line, or none — why a tap will open
  Blurt, the words still being made, the countdown, where the words went;
  the status line row of The two processes has every string. It is a key
  too: a tap on it does what it says, through the same path as a tap on
  the mic (`KeyboardModel.tapMic`), so the words and the tap can never
  disagree. Ready and idle is wordless, as Apple's bar is before the first
  word.
- **The Full Access note** as the whole bar, when the App Group is out of
  reach: without it nothing else here can work, and the user has to be told
  where to go. A tap opens Blurt's setup.
- **The term field** while a term is being typed (`TermField`): × · what
  you type, with a caret in the signal green · ✓.

The bar's height is Apple's suggestion bar's, and the keyboard's edges above
and beside the keys are the layout's: both are set through KeyboardKit's
styles from the layout configuration, and the parity run measures them
against Apple's (Apple's geometry, above); their numbers live there and in
The two processes, not here.

## Quick-add key term

The most-asked-for thing: Blurt mishears a niche word, and the fix has to take
seconds, inside the app you're typing in, never a trip to Settings. Two ways
in, both from the small **+** at the bar's trailing end.

**Highlight a word, tap once.** Select a word (or a short phrase) in your text
and the + grows into a chip — a key's own cap colour and hairline at the
field's 8 pt corner — holding the word, with a green **+** before it
(`AddTermKey`, `KeyboardModel.selectedTerm`). One tap adds the word as it
stands to Blurt's key terms; the text is not touched, a success haptic, and
the chip shows ✓ for 1.2 s — then gives way to the + even though the host may
keep the word highlighted for as long as you leave it (a chip that stayed
with the highlight read as stuck; `dismissedSelection`, tested). Only that
word's chip: another word highlighted within the 1.2 s keeps its own. A word
already in the list shows a quiet ✓ from the start, so selecting anything
tells you whether Blurt has it; a tap on that ✓ puts the + back. Highlight
another word and the chip is back for it. The selection is read off the host
field on every change (`selectionDidChange`, `textDidChange`); what counts as
a word is trimmed, one line, at most 48 characters (`termCandidate`, tested),
and only with Full Access, since the list lives in the App Group. The chip
grows from the trailing end towards the line, to `addterm/chip-max-width` at
most, so the status line keeps its room; a longer word truncates. **Hold the
chip** (0.6 s, the system's long press, so a touch the system takes away
never opens it) to open the field with the word in it instead — for the case
below.

**Type it.** Tap the + with nothing selected (or hold the chip) and the bar
becomes the field — × · what you type · ✓ — pre-filled with the selection if
there was one, and the keys type into it, not the host
(`BlurtActionHandler.routeToTerm`: characters, space and return on the
release KeyboardKit acts on, delete on its press and its repeat; shift and
the page keys fall through, so the pages still turn). A dictation in flight
is closed first: from the plain + a recording is released and the words
still land; from a highlighted word it is cancelled, since a result replaces
the selection and would land over the very word being fixed (tested). Shift
is on for the first letter and after a space (`termWantsUppercase`; the
controller sets KeyboardKit's case from it on every text change, because
KeyboardKit re-reads the host's sentence otherwise and the term's rule must
win). Type the right spelling; return or ✓ saves. The term goes into Blurt's
key terms (`BlurtKeyTerms` in the App Group, the AssemblyAI SDK's `KeyTerms`
rules: trimmed, deduplicated case-insensitively) and rides `keyterms_prompt`
on the very next dictation. If it began as a selection and you changed it,
the misheard word in your text is replaced with what you typed — only while
that highlight still stands where it was (a host can report a selection a
moment after the cursor moved, and inserting then would put the word in
twice). A success haptic, and the + shows a check for 1.2 s.

× or an empty save leaves the mode, and so does the keyboard going away. A
hardware keyboard types past the on-screen keys into the app's field; while
the term field is open a short run that appears there right after where the
cursor was is moved into the term and taken back out of the field — one
character at a time, as a key types; a block (a paste, the system's own
dictation under the keyboard) is never typing and stays — and never when the
field opened over a highlighted word, since collapsing that highlight grows
the text before the cursor by exactly the word (tested). The
list itself is edited in Settings → Transcription, which shows the count
against the request's cap of 100 terms.

## Sharing key terms

Words → Key terms → **Share key terms** puts the list in the share
sheet as a `.blurtterms` file (JSON — `name`, `from`, `terms`; a declared
document type, `com.assemblyai.blurt.terms`) with the words as the message text. A
tap on the file in Messages opens Blurt with "Add N key terms?": every term
ticked, untick any, Add merges the rest without duplicates. A
`blurt://terms?add=a,b,c&name=…&from=…` link does the same (`TermPack`,
`ImportTermsView`). A pack is refused over 64 KB, past 100 terms or with a
term, name or sender over 80 characters.

## Adapting to the phone's own keyboard settings

Nothing to configure, and nothing of Blurt's to get wrong: KeyboardKit reads
the host field into its context and draws what Apple would. The return key
says what the field asks — send, search, go, done, next, join — and `return`
otherwise (`returnKeyType`); a number or phone field opens on the keyboard
type it asks for, the number pad among them; capitalisation follows the
field's `autocapitalizationType`; the face follows its `keyboardAppearance`;
the globe appears only when iOS says the keyboard needs one
(`needsInputModeSwitchKey`). The letter rows are English —
`KeyboardApp.blurt` names the one locale — so QWERTY on every phone; the
other locales' layouts are KeyboardKit Pro's and out of scope.

## Hands-free

Off by default — a session comes on whenever Blurt is opened, so on by
default would record whenever a Blurt keyboard came up after, without a tap —
with a toggle in Settings → Keyboard: a dictation starts the moment the
keyboard comes up in a text field — the same synthetic tap through the
engine's gate, so it latches and the next tap of the mic stops it. Only when
the app is listening and nothing is in flight; otherwise the mic sits dimmed
and the first tap opens Blurt. When the keyboard leaves the screen with a
dictation it started, it releases a recording (the words still land, on the
clipboard if no keyboard is there) and cancels anything earlier. The
keyboard reads the toggle the next time it comes up.

## Tokens (`Design/tokens.json` → `BlurtDesign/DesignTokens.swift`)

The brand's colours, as the design system defines them and as the phone
uses them. `BlurtBrand` keeps a few of the Mac's names as aliases.

<!-- tokens:begin brand -->

| Token               | Value     | Swift                    | Use                                                                        |
| ------------------- | --------- | ------------------------ | -------------------------------------------------------------------------- |
| `black`             | `#000000` | `Brand.black`            | —                                                                          |
| `card`              | `#EBE8E8` | `Brand.card`             | the warm card fill; the paper theme's surface                              |
| `card-border`       | `#DEDBDB` | `Brand.cardBorder`       | the card's hairline; the paper theme's modifier key                        |
| `cobolt`            | `#3923C7` | `Brand.cobolt`           | AssemblyAI's primary violet: the drop, never a key or a surface            |
| `green/100`         | `#CCE4D5` | `Brand.green100`         | the design system's UI-and-code green fill (unused on the phone yet)       |
| `green/200`         | `#99C8AC` | `Brand.green200`         | the design system's UI-and-code green highlight (unused on the phone yet)  |
| `green/400`         | `#67AD82` | `Brand.green400`         | the brand hue lifted for dark chrome: the meter, the ring, the wave on ink |
| `green/700`         | `#01762F` | `Brand.green700`         | the wordmark green, light chrome (the app's accent in light)               |
| `green/mist`        | `#DBF5E6` | `Brand.greenMist`        | the pale green the orb lightens into                                       |
| `ink`               | `#1D1B16` | `Brand.ink`              | the brand ink: the Mac pill's body, the ink theme's surface                |
| `ink/600`           | `#3A362F` | `Brand.ink600`           | the Mac's dark card border                                                 |
| `ink/700`           | `#33302A` | `Brand.ink700`           | an ordinary key on ink, one step up                                        |
| `ink/800`           | `#26231E` | `Brand.ink800`           | a modifier key on ink; the Mac's dark card fill                            |
| `neutral/300`       | `#D2D1D0` | `Brand.neutral300`       | black-100: the lightest warm grey                                          |
| `neutral/500`       | `#A5A4A2` | `Brand.neutral500`       | black-200: mono labels on the dark face                                    |
| `neutral/700`       | `#777673` | `Brand.neutral700`       | black-300: muted text and mono labels on the light face                    |
| `neutral/900`       | `#4A4945` | `Brand.neutral900`       | black-400: body text on the light face                                     |
| `orange`            | `#E67F36` | `Brand.orange`           | the error word and ring, cancel, the Full Access note; never a red body    |
| `paper/200`         | `#ECEBE5` | `Brand.paper200`         | neutral-100: the light face's surface                                      |
| `paper/300`         | `#DAD7CB` | `Brand.paper300`         | neutral-200: a modifier key on the light face                              |
| `paper/400`         | `#C7C3B2` | `Brand.paper400`         | neutral-300: hairlines and field borders on the light face                 |
| `paper/page`        | `#FDFCF8` | `Brand.paperPage`        | the design system's page: the app's light ground                           |
| `paper/tint`        | `#F5F3EB` | `Brand.paperTint`        | the warm off-white one step in: light cards, dark legends                  |
| `violet/iris`       | `#887BDD` | `Brand.violetIris`       | the orb gradient's upper violet stop                                       |
| `violet/lavender`   | `#D7D3F4` | `Brand.violetLavender`   | the orb's lightest violet: its top and the gradient's ends                 |
| `violet/periwinkle` | `#B0A7E9` | `Brand.violetPeriwinkle` | the orb's mid violet: the drop's halo                                      |
| `warm-white`        | `#F2EEE6` | `Brand.warmWhite`        | key legends on ink: warm white on warm ink                                 |
| `white`             | `#FFFFFF` | `Brand.white`            | —                                                                          |

<!-- tokens:end brand -->

The app's catalog colours (`app/*`), each a light/dark pair the generator
also writes into the asset catalog's colour sets; the keyboard's own colours
are KeyboardKit's (The two faces, above):

<!-- tokens:begin keyboard -->

| Token                        | Value                                   | Swift                            | Use                                                                                           |
| ---------------------------- | --------------------------------------- | -------------------------------- | --------------------------------------------------------------------------------------------- |
| `app/accent-dark`            | `#67AD82` (`brand.green/400`)           | `Keyboard.appAccentDark`         | the catalog's AccentColor in dark                                                             |
| `app/accent-light`           | `#01762F` (`brand.green/700`)           | `Keyboard.appAccentLight`        | the catalog's AccentColor in light: Blurt green, the one accent every screen and the CTA take |
| `app/card-border-dark`       | `#3A362F` (`brand.ink/600`)             | `Keyboard.appCardBorderDark`     | the catalog's CardBorder in dark                                                              |
| `app/card-border-light`      | `#C7C3B2` (`brand.paper/400`)           | `Keyboard.appCardBorderLight`    | the catalog's CardBorder in light                                                             |
| `app/card-fill-dark`         | `#26231E` (`brand.ink/800`)             | `Keyboard.appCardFillDark`       | the catalog's CardFill in dark                                                                |
| `app/card-fill-light`        | `#F5F3EB` (`brand.paper/tint`)          | `Keyboard.appCardFillLight`      | the catalog's CardFill in light                                                               |
| `app/cta-dark`               | `#67AD82` (`keyboard.app/accent-dark`)  | `Keyboard.appCtaDark`            | the catalog's CTA in dark: the one accent button                                              |
| `app/cta-light`              | `#01762F` (`keyboard.app/accent-light`) | `Keyboard.appCtaLight`           | the catalog's CTA in light: the one accent button                                             |
| `app/cta-text-dark`          | `#1D1B16` (`brand.ink`)                 | `Keyboard.appCtaTextDark`        | the catalog's CTAText in dark: ink on green, as the site                                      |
| `app/cta-text-light`         | `#FFFFFF` (`brand.white`)               | `Keyboard.appCtaTextLight`       | the catalog's CTAText in light                                                                |
| `app/keep-open-tint-1-dark`  | `#67AD82` (`brand.green/400`)           | `Keyboard.appKeepOpenTint1Dark`  | tint 1 in dark                                                                                |
| `app/keep-open-tint-1-light` | `#01762F` (`brand.green/700`)           | `Keyboard.appKeepOpenTint1Light` | the drifting wordmark on the Blurt-is-on card, a colour per wall in turn: the accent first    |
| `app/keep-open-tint-2-dark`  | `#F5F3EB` (`brand.paper/tint`)          | `Keyboard.appKeepOpenTint2Dark`  | tint 2 in dark                                                                                |
| `app/keep-open-tint-2-light` | `#1D1B16` (`brand.ink`)                 | `Keyboard.appKeepOpenTint2Light` | then the text colour                                                                          |
| `app/keep-open-tint-3-dark`  | `#99C8AC` (`brand.green/200`)           | `Keyboard.appKeepOpenTint3Dark`  | tint 3 in dark                                                                                |
| `app/keep-open-tint-3-light` | `#67AD82` (`brand.green/400`)           | `Keyboard.appKeepOpenTint3Light` | then the green a step lighter                                                                 |
| `app/keep-open-tint-4-dark`  | `#A5A4A2` (`brand.neutral/500`)         | `Keyboard.appKeepOpenTint4Dark`  | tint 4 in dark                                                                                |
| `app/keep-open-tint-4-light` | `#777673` (`brand.neutral/700`)         | `Keyboard.appKeepOpenTint4Light` | then the muted grey, and round again                                                          |
| `app/muted-dark`             | `#A5A4A2` (`brand.neutral/500`)         | `Keyboard.appMutedDark`          | the catalog's Muted in dark                                                                   |
| `app/muted-light`            | `#777673` (`brand.neutral/700`)         | `Keyboard.appMutedLight`         | the catalog's Muted in light: eyebrows, captions, secondary text                              |
| `app/page-dark`              | `#1D1B16` (`brand.ink`)                 | `Keyboard.appPageDark`           | the catalog's Page in dark: ink, the website's ground                                         |
| `app/page-light`             | `#FDFCF8` (`brand.paper/page`)          | `Keyboard.appPageLight`          | the catalog's Page in light: the design system's page                                         |
| `app/text-dark`              | `#F5F3EB` (`brand.paper/tint`)          | `Keyboard.appTextDark`           | the catalog's Text in dark                                                                    |
| `app/text-light`             | `#1D1B16` (`brand.ink`)                 | `Keyboard.appTextLight`          | the catalog's Text in light                                                                   |

<!-- tokens:end keyboard -->

<!-- tokens:begin gradients -->

<!-- tokens:end gradients -->

## Metrics and motion

Every size, gap, radius, opacity and duration the app's screens and the
keyboard's own parts use. The keys' numbers among them — Apple's, measured
(Apple's geometry, above) — go to KeyboardKit's layout configuration
(`KeyboardLayoutConfiguration.blurt`), and the parity run checks what
KeyboardKit draws from them against Apple's keyboard. Every row here is read
by a view: the rows the hand-drawn keyboard alone read went with it.

<!-- tokens:begin metrics -->

| Token                        | Points   | Swift                             | Use                                                                                                                                     |
| ---------------------------- | -------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `addterm/chip-gap`           | `6`      | `Metrics.addtermChipGap`          | between the chip's glyph and the word                                                                                                   |
| `addterm/chip-max-width`     | `200`    | `Metrics.addtermChipMaxWidth`     | the widest the chip grows in the bar, so the status line keeps its room; a longer word truncates                                        |
| `addterm/chip-pad`           | `10`     | `Metrics.addtermChipPad`          | the selected-word chip's side padding                                                                                                   |
| `addterm/inset`              | `6`      | `Metrics.addtermInset`            | the bar's side padding: the status line from the leading edge, the + from the trailing one                                              |
| `app/button-height`          | `40`     | `Metrics.appButtonHeight`         | the brand's button                                                                                                                      |
| `app/button-pad`             | `12`     | `Metrics.appButtonPad`            | its side padding                                                                                                                        |
| `app/card-pad`               | `16`     | `Metrics.appCardPad`              | inside a card                                                                                                                           |
| `app/chip-gap`               | `8`      | `Metrics.appChipGap`              | between chips                                                                                                                           |
| `app/chip-pad-x`             | `12`     | `Metrics.appChipPadX`             | a style chip's side padding                                                                                                             |
| `app/chip-pad-y`             | `8`      | `Metrics.appChipPadY`             | and its top and bottom                                                                                                                  |
| `app/header-height`          | `44`     | `Metrics.appHeaderHeight`         | the home header: wordmark and gear                                                                                                      |
| `app/hero-gap`               | `14`     | `Metrics.appHeroGap`              | between the hero's pieces                                                                                                               |
| `app/icon`                   | `20`     | `Metrics.appIcon`                 | the header's gear, the copy glyph                                                                                                       |
| `app/input-pad-y`            | `10`     | `Metrics.appInputPadY`            | an app input's top and bottom (its sides are app/chip-pad-x)                                                                            |
| `app/line-gap`               | `6`      | `Metrics.appLineGap`              | between lines of one thought                                                                                                            |
| `app/page-pad`               | `20`     | `Metrics.appPagePad`              | the screens' side padding                                                                                                               |
| `app/pill-pad-y`             | `4`      | `Metrics.appPillPadY`             | a key-term pill's top and bottom, and its side beside the ×                                                                             |
| `app/pill-remove`            | `24`     | `Metrics.appPillRemove`           | the × on a key-term pill: its tap square                                                                                                |
| `app/row-pad-y`              | `8`      | `Metrics.appRowPadY`              | a list row's top and bottom inside a card                                                                                               |
| `app/row-remove`             | `32`     | `Metrics.appRowRemove`            | the × on a text-shortcut row: its tap square                                                                                            |
| `app/section-gap`            | `24`     | `Metrics.appSectionGap`           | between the home screen's sections                                                                                                      |
| `app/setup-number-width`     | `24`     | `Metrics.appSetupNumberWidth`     | the setup steps' mono numerals                                                                                                          |
| `app/stack-gap`              | `12`     | `Metrics.appStackGap`             | between a section's eyebrow and its content, and between cards                                                                          |
| `app/stat-gap`               | `16`     | `Metrics.appStatGap`              | between the stats in the card, and between its rows                                                                                     |
| `app/tab-gap`                | `4`      | `Metrics.appTabGap`               | between a tab's icon and its label                                                                                                      |
| `app/tab-height`             | `52`     | `Metrics.appTabHeight`            | a tab in the brand tab bar: its icon over its mono label                                                                                |
| `app/try-box-height`         | `64`     | `Metrics.appTryBoxHeight`         | the least height of the home screen's "Try it here" box: two lines                                                                      |
| `card/border`                | `1`      | `Metrics.cardBorder`              | the card's hairline                                                                                                                     |
| `card/radius`                | `12`     | `Metrics.cardRadius`              | the app's cards (radius/card)                                                                                                           |
| `caret/height`               | `20`     | `Metrics.caretHeight`             | —                                                                                                                                       |
| `caret/lead`                 | `1`      | `Metrics.caretLead`               | the caret's gap from the text                                                                                                           |
| `caret/radius`               | `1`      | `Metrics.caretRadius`             | —                                                                                                                                       |
| `caret/width`                | `2`      | `Metrics.caretWidth`              | —                                                                                                                                       |
| `glyph/hit`                  | `44`     | `Metrics.glyphHit`                | the +, × and ✓ touch targets: the HIG's 44 pt square around a size/glyph symbol                                                         |
| `keep-open/corner-tolerance` | `4`      | `Metrics.keepOpenCornerTolerance` | touching one edge this close to the other counts as an exact corner                                                                     |
| `keep-open/flare-arm`        | `3`      | `Metrics.keepOpenFlareArm`        | the corner flare's vertical arm, as a fraction of the wordmark's height                                                                 |
| `keep-open/flare-core`       | `5`      | `Metrics.keepOpenFlareCore`       | the flare's bright centre                                                                                                               |
| `keep-open/flare-span`       | `1.6`    | `Metrics.keepOpenFlareSpan`       | and its horizontal arm, as a fraction of the wordmark's width                                                                           |
| `keep-open/flare-width`      | `1`      | `Metrics.keepOpenFlareWidth`      | the flare's lines                                                                                                                       |
| `keep-open/speed`            | `64`     | `Metrics.keepOpenSpeed`           | how far it drifts along each axis in a second, so the path is the 45° zigzag                                                            |
| `keep-open/wordmark-height`  | `44`     | `Metrics.keepOpenWordmarkHeight`  | the wordmark drifting on the Blurt-is-on card: twice the header's                                                                       |
| `key/abc-width-402`          | `43.333` | `Metrics.keyAbcWidth402`          | 123, the globe and the mic at 402 pt: the iPhone's small bottom-row key, pinned so every other cap keeps Apple's width                  |
| `key/gap`                    | `6`      | `Metrics.keyGap`                  | between caps, the iPhone's: half each side is KeyboardKit's cell inset                                                                  |
| `key/height`                 | `43`     | `Metrics.keyHeight`               | every cap: the iPhone's, measured (apple-geometry-glass-402.json); with row/gap it is KeyboardKit's row height                          |
| `key/min-width`              | `43.333` | `Metrics.keyMinWidth`             | the probe field's height in the app: the iPhone's 123 key at 402 pt                                                                     |
| `key/radius`                 | `8`      | `Metrics.keyRadius`               | every cap's corner: the iPhone's (fitted 8.17), set on KeyboardKit's button style                                                       |
| `key/reference-width`        | `402`    | `Metrics.keyReferenceWidth`       | the width the @402 tokens were measured at (iPhone 18 Pro); widths scale from it                                                        |
| `margin/bottom-keys`         | `13`     | `Metrics.marginBottomKeys`        | under the bottom row of caps: the iPhone's; less half a row gap is KeyboardKit's bottom edge inset                                      |
| `margin/side`                | `6.5`    | `Metrics.marginSide`              | at the keyboard's sides: the iPhone's cap margin, (402 − 10 letters − 9 gaps) / 2; less half a key gap is KeyboardKit's edge inset      |
| `margin/vertical`            | `8.667`  | `Metrics.marginVertical`          | between the bar and the first row of caps: with voicebar/height it is the iPhone's 52.667 pt band above the keys                        |
| `opacity/disabled`           | `0.4`    | `Metrics.opacityDisabled`         | the + without Full Access; a brand button that can't be pressed yet                                                                     |
| `opacity/glint`              | `0.95`   | `Metrics.opacityGlint`            | the cross glint when the words land                                                                                                     |
| `opacity/grain-dark`         | `0.14`   | `Metrics.opacityGrainDark`        | film grain over the dark face: matte, the brand's texture                                                                               |
| `opacity/legend-muted`       | `0.5`    | `Metrics.opacityLegendMuted`      | the + at rest                                                                                                                           |
| `opacity/off`                | `0.6`    | `Metrics.opacityOff`              | the mic key's glyph when Blurt isn't ready — dim and still, but there: a tap opens the app                                              |
| `opacity/placeholder`        | `0.4`    | `Metrics.opacityPlaceholder`      | the field's placeholder                                                                                                                 |
| `opacity/press-brighten`     | `0.15`   | `Metrics.opacityPressBrighten`    | a key lightens this much while pressed                                                                                                  |
| `opacity/pressed`            | `0.85`   | `Metrics.opacityPressed`          | a brand button while pressed: a colour change, no lift                                                                                  |
| `opacity/term-cancel`        | `0.7`    | `Metrics.opacityTermCancel`       | the field's ×                                                                                                                           |
| `radius/button`              | `4`      | `Metrics.radiusButton`            | the brand's buttons and the grille: rectangular, never a pill                                                                           |
| `radius/hero`                | `16`     | `Metrics.radiusHero`              | the brand's featured cards                                                                                                              |
| `radius/input`               | `8`      | `Metrics.radiusInput`             | the brand's inputs: the key-term field                                                                                                  |
| `row/gap`                    | `11`     | `Metrics.rowGap`                  | between rows, the iPhone's: half above and half below is KeyboardKit's cell inset                                                       |
| `stat/part-gap-ratio`        | `0.38`   | `Metrics.statPartGapRatio`        | between a stat's number-and-unit parts, as a fraction of its size                                                                       |
| `stat/tracking-ratio`        | `-0.03`  | `Metrics.statTrackingRatio`       | a stat number's tracking, as a fraction of its size                                                                                     |
| `stat/unit-gap-ratio`        | `0.15`   | `Metrics.statUnitGapRatio`        | between a number and its unit, as a fraction of its size                                                                                |
| `stat/unit-ratio`            | `0.46`   | `Metrics.statUnitRatio`           | a stat's mono unit (hr, min, sec) as a fraction of its number's size                                                                    |
| `term/border`                | `1`      | `Metrics.termBorder`              | the field's hairline                                                                                                                    |
| `term/gap`                   | `8`      | `Metrics.termGap`                 | × · field · ✓                                                                                                                           |
| `term/height`                | `36`     | `Metrics.termHeight`              | the key-term field's capsule                                                                                                            |
| `term/inset`                 | `2`      | `Metrics.termInset`               | the field row's side inset                                                                                                              |
| `term/pad`                   | `14`     | `Metrics.termPad`                 | the field's side padding                                                                                                                |
| `term/radius`                | `8`      | `Metrics.termRadius`              | the key-term field: the brand's input corners (radius/input)                                                                            |
| `typing/field-border`        | `2`      | `Metrics.typingFieldBorder`       | the typing field's border, orange once a word goes wrong                                                                                |
| `typing/field-pad`           | `12`     | `Metrics.typingFieldPad`          | inside the typing field                                                                                                                 |
| `typing/line-spacing`        | `8`      | `Metrics.typingLineSpacing`       | between the lines of words to type                                                                                                      |
| `typing/pulse`               | `1.06`   | `Metrics.typingPulse`             | the countdown's thump in the last five seconds                                                                                          |
| `typing/result-gap`          | `20`     | `Metrics.typingResultGap`         | between the result's blocks                                                                                                             |
| `typing/words-height`        | `180`    | `Metrics.typingWordsHeight`       | the least room the words take, so the field below stays put                                                                             |
| `voicebar/height`            | `44`     | `Metrics.voicebarHeight`          | the bar above the keys (KeyboardKit's toolbar), in the slot Apple's suggestion bar takes: the status line, the + and the key-term field |
| `wordmark/height`            | `22`     | `Metrics.wordmarkHeight`          | —                                                                                                                                       |

<!-- tokens:end metrics -->

Motion. Nothing of Blurt's springs or snaps. Colour and fill changes ease
over the brand's transition; everything else moves on the house curve
(`ease/signature`, `cubic-bezier(0.22, 1, 0.36, 1)`).

<!-- tokens:begin motion -->

| Token                    | Value           | Swift                        | Use                                                                                              |
| ------------------------ | --------------- | ---------------------------- | ------------------------------------------------------------------------------------------------ |
| `caret`                  | `0.5`           | `Motion.caret`               | the caret's blink                                                                                |
| `chip-hold`              | `0.6`           | `Motion.chipHold`            | holding the chip opens the field instead of adding; longer than a firm tap                       |
| `colour`                 | `0.2`           | `Motion.colour`              | a colour or fill changing state: the brand's transition                                          |
| `ease/signature`         | `0.22,1,0.36,1` | `Motion.easeSignature`       | the house curve for everything that moves; nothing springs                                       |
| `keep-open-fade`         | `0.6`           | `Motion.keepOpenFade`        | the Blurt-is-on card fading in over the app as the scene leaves the front, and out as it returns |
| `keep-open-first-corner` | `9`             | `Motion.keepOpenFirstCorner` | the first exact corner, this long after the card appears; the rest come as the screen allows     |
| `keep-open-flare`        | `0.9`           | `Motion.keepOpenFlare`       | the cross flare when the wordmark lands in a corner                                              |
| `key-press`              | `0.08`          | `Motion.keyPress`            | a key lighting                                                                                   |
| `space-hold`             | `0.25`          | `Motion.spaceHold`           | the space bar's hold before it moves the cursor: KeyboardKit's half second made it wait          |
| `state-fade`             | `0.5`           | `Motion.stateFade`           | every change on the mic key and the +: a glyph, the tint, the dimming                            |
| `term-swap`              | `0.4`           | `Motion.termSwap`            | the bar becoming the key-term field                                                              |
| `typing-flash`           | `0.15`          | `Motion.typingFlash`         | the typing field's border turning, and the countdown's thump                                     |
| `typing-tick`            | `0.1`           | `Motion.typingTick`          | how often the typing test's clock and live speed redraw                                          |

<!-- tokens:end motion -->

## The app's screens (`BlurtiOS/Sources/`)

The Blurt landing page on a phone, in the phone's appearance: the page under
the brand's grain; the wordmark (tinted with the accent) and the gear across
the top; sections under mono eyebrows; serif headlines (the system serif, 34),
body in the system face (16, captions 14); cards with 12 pt corners and a 1 pt
hairline (the hero 16), no shadows; chips and buttons rectangular at 4 pt,
buttons 40 pt tall with their label in uppercase mono, one green button per
row (Cam's rule) and a hairline one beside it, a colour change on press and
never a lift. Glyphs are SF Symbols — the platform's — where the web brand
uses Material Symbols.

**Tabs** (`MainView`, `BrandTabBar`): Dictate and Words under the brand tab
bar — each tab's icon over its mono label, the selected one in the accent, a
hairline above. Settings opens from either tab's gear; the consent sheet and a
shared key-term list arrive whichever tab is showing (a list switches to Words).

**Words** (`WordsView`, `WordsEdit`): the serif `Words` headline and the gear;
two cards. `KEY TERMS`: the terms as pills (full radius, the page's fill, a
hairline, × to remove; `FlowLayout`), an input and `ADD` (commas add several;
duplicates of any case drop; 100 at most, the request's cap), the count and the
contact names that come along, and Share. `TEXT SHORTCUTS`: each phrase in mono
accent over its replacement, × to remove, between hairlines; two inputs and
`ADD SHORTCUT` (re-adding a phrase replaces it). Brand buttons fade while
disabled (`opacity/disabled`).

**First run** (`RootView`, `SetupView`, `SetupSteps`, `SetupProgress`): in
place of the tabs until Blurt is set up — the wordmark, a serif headline, and
`SET UP BLURT` in a card, its three steps numbered `01 02 03` in mono (a check
once done): the API key inline (a secure field, `CONTINUE`, `GET A FREE KEY`,
and where the key and the audio go), the microphone, the keyboard. Without a
key it can't be left; with one, `START DICTATING` goes to the tabs and the rest
can wait. Afterwards the steps live in Settings › Setup, folded to "Blurt is
set up ✓ · Show steps" while everything is done and open while anything isn't.
Whoever was already set up skips it.

**Home** (`HomeView`, `HomeHero`, `StyleChips`, `RecentSection`,
`HomeStatus` for the words; `StatsCard`): the lifetime stats — `DICTATIONS`,
`WORDS`, `TIME SAVED` (against 36 wpm, the phone average, or the easter egg's
result) as serif numbers with mono units, one row until time saved reaches an
hour and then two, at the largest of four sizes that fits (reset in Settings ›
Data); the session card — on by itself whenever Blurt comes to the front with nothing
to ask (a key, consent and the microphone all given), so the keyboard is ready
without the switch, unless the user turned it off: off with the switch holds,
across launches, until the switch or the keyboard's mic asks for a session
(`SessionAutoStart`) — `SESSION ON` in the
accent or `SESSION OFF` muted, with the switch beside it that opens and closes
the listening window (off without a key; `OPEN SETTINGS` instead when the
microphone was refused), one line (what to do, and "Ends after 15 idle
minutes."), and "Try it here" (`TryItBox`), a box to try the Blurt keyboard in:
iOS remembers the keyboard last used in it, so after the first switch with the
globe key it opens on Blurt, and the keyboard inserts at the cursor; a drag
down the page puts the keyboard away. A dictation's phases stay on the
keyboard; only a failure shows, in orange, and "The session is off. Turn it on
to dictate." goes once a session is on. After
the keyboard opened the app to start a session, a green banner points at iOS's
◀ back link until the user leaves. `STYLE` and the chips, the active one filled;
`RECENT` and the cards (three lines, the style as a green mono tag, the
time, a copy button); `POWERED BY ASSEMBLYAI`.

**Settings** (`SettingsView`): a form on the page, its sections under
eyebrows — Keyboard (hands-free), Listening (the window),
Transcription (enhanced transcripts, output styles), Account (the API key, and where to get one),
About (with AssemblyAI's privacy policy). Styles, the import sheet, the key entry and the consent
sheet share the form's chrome (`brandForm()`).

**The easter egg** (`TypingTestView`, `TypingTest`, `TypingSpeed`): a quiet
"How fast can you type?" link at the foot of Settings opens a 30-second sprint
over common words, full screen — a mono countdown that turns orange and thumps
through the last five seconds (no thump under Reduce Motion), live WPM in the
accent, the current word underlined, wrong words struck through in orange,
the field's border orange once a word goes wrong. The result: WPM, a rank,
accuracy, the best, and talking's 150 wpm against yours; the latest result
becomes time saved's typing speed ("Using your N wpm · Reset to average").

**Styles** (`StylesView`, `StylePreset`): `YOUR STYLES` (Default, then each
of the user's, the active one checked; tap to use, the pencil to edit),
`START FROM A PRESET` (Professional, Casual and Ultracasual, each with its icon and a line of its text; one tap adds it as a
style and switches to it, an added one shows a check), and `NEW STYLE` pinned
underneath, whose editor starts with the presets as equal-width chips that fill
in the name and the instructions.

**Consent** (`ConsentView`, `AIConsent`): before the listening window first
opens, a sheet names AssemblyAI, lists what is sent (the voice while
dictating, the text before the cursor, recent dictations, key terms with
contact names) and links the privacy policy; `ALLOW` records it and opens the
window. App Review 5.1.2(i). The list is what `AIConsent.version` covers:
sending anything new means a new version, and everyone is asked again.

**Blurt is on** (`KeepOpenView`, `KeepOpen`, `Bounce`): the app-switcher
card. Whenever the scene leaves the front with a listening window on — the
swipe up to the switcher, the home gesture — `RootView` fades a full-screen
page in over whatever the app was showing (`keep-open-fade`, 0.6 s on the
house curve; a layer, never a presentation), and fades it out again when the
app comes back to the front. That page is what iOS shows as Blurt's card in
the switcher and keeps as its snapshot, so the card says the one thing the
user has to know there: `BLURT IS ON` in the accent, the serif "Keep Blurt in
the background.", and a line saying to leave it here and the Blurt keyboard
dictates in any app, and for how long it listens after the last word, in
Settings' words (15 minutes, 1 hour, or until you stop it). Nothing on it is
tapped: the scene is inactive whenever it shows. Without a window — the
session off — the switcher shows the app as it was.

Above the words, the screensaver — the DVD player's — on a little screen of
its own: a card (the hairline, at the button's 4 pt corner, square enough that
a corner reads as one) filling the room between the header and the words. The
wordmark, twice the header's (44), drifts across it at 64 pt/s on both axes
and turns back off every edge, so the path is the 45° zigzag, and it takes the
next of four colours at every wall it touches (the accent, the text, a lighter
green, the muted grey; `app/keep-open-tint-*`, easing over `colour`). Touch
one edge within 4 pt of the other and it is an exact corner: the grille's
cross flare at the wordmark's scale over the corner it landed in (the upright
3 × its height, the arm 1.6 × its width, a green and a violet fringe as light,
gone over 0.9 s, clipped to the screen), a success haptic, and one more on the
mono `CORNERS · N` in the top corner. Exact corners are rare by nature, so the
start is chosen to land the first one 9 s in (`keep-open-first-corner`); after
that they come as the screen allows. Every frame is a function of the time
since the card appeared (`Bounce`, tested: the reflection, the wall count, the
corner and its tolerance, the parked frame). Reduce Motion parks the wordmark
dead centre in the accent and drops the tally.

`-BlurtSettings` opens Settings as the root for a screenshot, and
`-BlurtKeepOpen` Blurt is on (`-BlurtGalleryStill` parks it); `xcrun simctl
ui booted appearance dark` before any capture for the dark appearance;
`-BlurtStartListening` opens the mic at launch (and grants AI consent, which a scripted run can't tap through).

## Feedback and accessibility

Haptics (`KeyboardModel.haptics`): medium impact on `recording`, light on the
stop, `.success` on pasted/copied, `.error` on error — with one line of words
at most, they are half of the feedback. The click on the mic's press is
KeyboardKit's, as on every key. The DX7 start/stop cues play in the app, not
the keyboard. The mic key is a button labelled Dictate / Stop dictation /
Start Blurt (`VoiceState.accessibilityLabel`) whose value is the error
message; the glyph carries no label of its own. The bar's line and note are
buttons that say their text; the chip says whether the word is a key term
and that a hold edits it first. Under Reduce Motion the caret holds steady;
the waveform still follows the level.

## The two processes, and every number

The app listens and transcribes; the keyboard is a remote control. They talk
over the App Group's `UserDefaults` (payloads as JSON) plus Darwin
notifications that carry nothing and just say "look" (`BlurtiOSCore/SharedState.swift`).

| Rule                    | Value                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Why                                                                                                                                                                                                      |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| presence                | `SharedStore.appHeartbeatInterval` 5 s (the app, while its window is open), `SharedStore.keyboardHeartbeatInterval` 4 s (the keyboard, while on screen); `SharedStore.presenceWindow` 15 s                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | more than twice a heartbeat, so one missed beat isn't absence; a killed process is absent within seconds                                                                                                 |
| keyboard presence       | one `KeyboardPresenceRecord` under `Key.keyboardPresence` — `processID` (`KeyboardProcess.id`, drawn once per keyboard process), `controllerID` (one per host field), `pid`, `seenAt`, `onScreen` — written on every appearance and every keyboard beat, `onScreen: false` on leaving, and signalled with `Signal.keyboard`; written over its own process's record only, as read the moment before (`SharedStore.writeKeyboardPresence(_:ifOwnedBy:)`; UserDefaults has no compare-and-write), and only while the record is its own controller's                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | a keyboard leaving in one host must not erase the one that just came up in another, nor the next field's in its own process; the watchdog and the relay read one record (`SharedStore.keyboardOnScreen`) |
| leaving with a stop out | `KeyboardModel.leaveGrace` 1.2 s (`BlurtShared.stopDeadline`): a keyboard leaving the screen with its own release or cancel still out keeps its record on screen until the app's ack settles the stop, or that long, whichever first; with nothing out, presence ends at once                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | the release command and the `keyboard` signal race: a record already off screen has the owner watchdog release the dictation the command is ending — a second release, logged as a dead keyboard         |
| readiness record        | `listeningState` + the `state` signal: `launchID`, `sequence`, `window`, `idle`, `micLive`, `reason` (`ListeningState`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | no stale "ready" after a relaunch or a close; the keyboard decides between a press and a hop from this and nothing else                                                                                  |
| readiness lease         | `ListeningState.lease` 15 s, renewed every `SharedStore.appHeartbeatInterval` (5 s); never `distantFuture`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | a killed or suspended app reads as absent within 15 s                                                                                                                                                    |
| listening               | `isReady`: window `open` **and** `micLive` **and** the lease not lapsed                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | a killed app, a phone call or a dead mic, with the window's end still in the future                                                                                                                      |
| window lifetime         | `SharedStore.windowMinutes` after the last word (`utteranceEnded`); floor `SyncSTTLimits.maxAudioSeconds` 1200 s from a recording's start; `ListeningWindowMachine.untilStopped` 0 = until stopped                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | "Ends after N idle minutes" is literally true, and a short window can't end a long dictation partway                                                                                                     |
| interruption → resume   | a call, Siri or another app's recording ends the utterance (words kept) and pauses the window; resume on `.ended` by polling `source.isOpen` every `ListeningWindow.resumePollStep` 50 ms for `ListeningWindow.resumePoll` 500 ms, never a start from the background; on the next foreground, a start; a call longer than the background task costs one hop                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | the window is never closed over a pause; iOS refuses a recording started from the background                                                                                                             |
| background task         | `BlurtShared.releaseBackgroundTask` 25 s, around an interruption (`ListeningWindow.interruptionTask`, `blurt.interruption`) and from a release to the dictation's terminal phase (`DictationCoordinator.releaseTask`, `blurt.release`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | the words of a dictation cut short still land after the host put Blurt in the background                                                                                                                 |
| owner watchdog          | `BlurtShared.ownerWatchdog` 10 s: the owner keyboard's presence not on screen or older than that while a dictation is in flight → one release, words kept; asked every keyboard beat and on the `keyboard` signal; another keyboard's record off screen counts only once it is that old, since it may have landed over the owner's beat                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | a dead keyboard never leaves the mic on for the `SyncSTTLimits.autoReleaseSeconds` 1195 s cap                                                                                                            |
| press ack               | `BlurtShared.pressDeadline` 1.2 s: a press with no `CommandAck` (`Key.ack`, `Signal.ack`) and no phase naming it (`PhaseSnapshot.answers`) by then is unanswered (`PressHandshake`): the gate resets, the line says "Tap to open Blurt", and the next tap hops with `unanswered`; the app answers `started`, `busy` (a dictation already in flight: the tap latches onto it) or `notListening` with the record's reason, and the ack is stamped with the app's `launchID`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | a press is a promise the app has to answer: a gate latched over a press nobody read would hold the next tap                                                                                              |
| stop ack                | `BlurtShared.stopDeadline` 1.2 s: a release or cancel with no ack by then is let go on the keyboard — the gate settles, and the app's watchdog ends the dictation if its keyboard is gone; a terminal phase for the dictation ends the stop sooner                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | a stop whose answer was lost must not hold the gate over a dictation already over                                                                                                                        |
| command retry           | one resend of the same command — same id, stamp and text — at `KeyboardModel.commandRetryDelay` 600 ms (`PressHandshake.defaultRetryDelay`) with no answer, for a press and for a stop alike; the app answers a resend with the command's original outcome (`CommandRouter`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | a missed Darwin notification would leave the gate latched over nothing; the second copy never starts a second dictation                                                                                  |
| hop URLs                | `blurt://start?reason=<FailureReason>` opens a window (`BlurtShared.startURL`, read back by `BlurtShared.hopReason`): `sessionOff`, `needsForeground`, `opening`, `interrupted`, `micBusy`, `micSilent`, `mediaReset`, `noKey`, `noConsent`, `micDenied` and `network` from the app's record or ack, `unanswered` and `suspended` derived by the keyboard; `blurt://setup?need=fullAccess` (`BlurtShared.setupURL`, `BlurtShared.fullAccessNeed`) shows the setup step and opens none                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | the keyboard says why it hopped; a keyboard without Full Access can't dictate whatever the app does                                                                                                      |
| hop return              | the hop carries the host app's bundle id (`BlurtShared.startURL(reason:host:)`, read back by `BlurtShared.hopHost`; the keyboard reads it off its controller or a parent, `HostApp.bundleID`, private and read only where a getter or ivar is declared); once a record says the window is open and the mic will stay live without the app in front — at once under a held mic, on the keeper's report under Picture in Picture (`idle: pip`), or `BlurtShared.hopReturnCap` 1.5 s past the open if the keeper has not reported (`HopReturn.isReady`) — the app brings the host back (`HostReturn.open`, `LSApplicationWorkspace`'s `openApplicationWithBundleID:`) and leaves; a window that closes before it opened, or the user leaving first (`DictationCoordinator.sceneLeft`), cancels it; no host on the hop (Blurt's own box, or an iOS that moved the id), or the call refused, leaves the "◀" hint                                                                                                                                                                                                                                                                                                                                                     | a session turned on from the keyboard costs one flash of Blurt and no swipe; the mic never leaves the front before it may                                                                                |
| audio session           | `.playAndRecord` / `.default` / `[.defaultToSpeaker, .allowBluetoothA2DP]` (`SystemAudioSession.baseOptions`), `.allowBluetoothHFP` only with "Use AirPods mic" (`SharedStore.airPodsMic`, off by default); `setAllowHapticsAndSystemSoundsDuringRecording(true)` before `setActive`; `setPreferredInput(builtInMic)` after activation and on every route change unless the opt-in; `setActive(false)` skipped while interrupted; never `.mixWithOthers`, never a keep-alive sound                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Typeless's own session, read off a phone log (2026-11-04); music on AirPods stays stereo for the window; deactivating during a call throws                                                               |
| idle keeper             | `-BlurtIdleMode pip` (the default where Picture in Picture is supported): one frame of `PictureInPictureKeeper.frameWidth` 4683 × `frameHeight` 1, a layer `sourceSize` 369 × 0.079 pt, which iOS frames at 112 × 0 pt; the mic opens per dictation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Typeless's shape, read off a phone log (2026-11-04): a Picture in Picture scene gives the process the foreground role a recording's start needs                                                          |
| result freshness        | `KeyboardModel.resultFreshnessWindow` 10 s                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | a notification held for a suspended keyboard arrives minutes late                                                                                                                                        |
| result addressing       | `recipient` = the keyboard process that sent the accepted stop, else the one whose press started the dictation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | two live keyboards (two host apps) must not both insert                                                                                                                                                  |
| result delivery         | the app waits `KeyboardRelayInjector.deliveryTimeout` 3 s (every `KeyboardRelayInjector.deliveryPoll` 250 ms) for the keyboard to take the result; else clipboard + "Copied"                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | "Pasted" is never a guess                                                                                                                                                                                |
| result re-signal        | once, at `KeyboardRelayInjector.resignalAfter` 1 s, if the result is still there                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | a missed Darwin notification costs a second one, not the words                                                                                                                                           |
| command freshness       | `BlurtShared.commandFreshnessWindow` 10 s                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | a held press from minutes ago must not start a dictation on resume                                                                                                                                       |
| phase staleness         | notices `PhaseSnapshot.noticeStaleAfter` 3 s (the longest dwell + 1); in flight `PhaseSnapshot.inFlightStaleAfter` 1210 s (`SyncSTTLimits.maxAudioSeconds` 1200 s + 10)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | the keyboard reads the snapshot on every appearance                                                                                                                                                      |
| notice dwell            | `PhaseSnapshot.pastedDwell` 1.2 s; `PhaseSnapshot.noticeDwell` 2 s for copied and error                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | the Mac's 0.8 / 1.6 s, a little longer with no hover                                                                                                                                                     |
| status line             | `VoiceNotice.line` (`KeyboardModel.statusLine`): one line under the mic, or none. Precedence: no Full Access — "Allow Full Access in Settings" (a tap opens the setup); then the phase's own notice — an error's reason, "Copied to the clipboard", "Still transcribing…" after `VoiceNotice.transcribingPatience` 3 s of processing (a tap buzzes), the countdown "30 s left" … "1 s left" through the last `VoiceNotice.countdownWindow` 30 s before `SyncSTTLimits.autoReleaseSeconds`; then the readiness line, one per `FailureReason` (`FailureReason.line`): "Tap to open Blurt" (`sessionOff`, `unanswered`, `suspended`), "Open Blurt to start" (`needsForeground`, `opening`), "Mic paused by a call — tap to open Blurt", "Another app has the mic — tap to open Blurt", "The mic went silent — tap to open Blurt", "Audio was reset — tap to open Blurt", "Add your API key in Blurt", "Open Blurt to continue", "Allow the microphone in Settings", "No connection — tap to try again" (the one that presses again rather than hopping); nil while the handshake has a press, a dictation or a stop in hand, and while ready and idle. The strings live in `VoiceNotice.Copy`; a tap on the line does what it says, through `KeyboardModel.tapMic` | the words and the tap never disagree; ready and idle is wordless, as Apple's keyboard is                                                                                                                 |
| held error              | `KeyboardModel.heldError`: the last `.error` phase, kept for the line after `PhaseSnapshot.noticeDwell` 2 s settles the picture back to idle; cleared by the next finger down on the mic, never by time                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | the words say why until the user acts; the picture settles as the Mac's pill does                                                                                                                        |
| tap travel              | `KeyboardInteraction.tapTravel` 12 pt: the chip (the +) acts on release only if the finger travelled less; the keys' touches are KeyboardKit's                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | a swipe that started on the chip adds nothing                                                                                                                                                            |
| level publish           | every 80 ms while recording — a literal in `DictationCoordinator.observeLevels`, the app side's to name (see the app side's rows below)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | the element's meter, off the capture path's back                                                                                                                                                         |
| silence watchdog        | `UtteranceFeed.silenceSeconds` 1 s of digital silence (every sample zero) in an open utterance → the source says `silent` → the window pauses with `micSilent`; held off for every start and again on a route change until the first chunk with sound, at most `UtteranceFeed.startGraceSeconds` 3 s                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | no live route delivers a second of exact zeros; a route coming up, held or parked, delivers them; a dead mic is said, not recorded                                                                       |
| home error              | `HomeStatus.errorDwell` 3 s, cleared sooner by any change of the window's state                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | a headline about a failure never outlives the session it happened in                                                                                                                                     |
| lexicon refresh         | `KeyboardModel.lexiconRefreshInterval` 3600 s (hourly)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | thousands of contacts on a keyboard memory budget                                                                                                                                                        |
| the bar                 | `voicebar/height` 44 pt (`Keyboard.ToolbarStyle`), above the keys in the slot Apple's suggestion bar takes; `margin/vertical` 8.667 pt under it, so the band above the first row is Apple's 52.667 pt                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | the status line, the + and the key-term field live there; the keys are KeyboardKit's                                                                                                                     |
| the mic's place         | `KeyboardLayout.blurt(for:)`: the mic after space at the 123 key's width, `key/abc-width-402` 43.333 pt plus `key/gap` 6 pt as the cell, on every page with a space bar and never on the number pad                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Apple's dictation mic sits in the host's bar below the keyboard, which no extension can draw into; every other cap keeps Apple's width                                                                   |
| the visual numbers      | see Metrics and motion above                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | generated from `Design/tokens.json`; the views carry no literals                                                                                                                                         |
| term packs              | ≤ `TermPack.fileCap` 64 KB, ≤ `KeyTerms.termCap` 100 terms, ≤ `TermPack.lengthCap` 80 characters each                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | the request's cap; unbounded input from a stranger                                                                                                                                                       |
| log subsystem           | `BlurtShared.logSubsystem` `com.assemblyai.blurt.iphone`: the app's `HostIdentity.subsystem`, and the keyboard's `KeyboardLog` (`Keyboard`) and `Container` loggers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | one predicate reads both processes; the engine's `HostIdentity` is never configured in the keyboard's process, so a logger of its own would write under the Mac app's name                               |

<!-- app-side:begin — the app side's review adds its rows here; every number a named constant -->

**The app side's rows** land here from its review. Until they do, one number
in the table is still a literal in the app: the level publish's 80 ms
(`DictationCoordinator.observeLevels`).

<!-- app-side:end -->

Tests pin the rules that can be pinned (`BlurtiOSTests`: the contract, the
gate, results, the term field, the feed, the layout with the mic, Apple's
geometry, the interaction rules, the voice state, the home's words, the
tokens); anything that gains a number here should gain a line there.
`SessionContractNumbersTests` reads every number in this table off its named
constant, asserts the value the row documents, and greps this section for the
constant's name beside the value the code holds — so a constant that moves
fails until its row says the new number, and a row reworded away from its
constant fails the same way.

## Where Blurt diverges from the brand system, on purpose

- Green is the UI signal (the system says cobolt-only): Cam's rule for the
  collab brand — inside the Assembly palette, off primary cobolt. On the
  keyboard it is one of the two brand colours left, beside the notice
  orange; everything else there is Apple's.
- The keyboard is Apple's, not the brand's: KeyboardKit draws Apple's keys in
  Apple's colours, type and corners, because a keyboard has to be native
  under the fingers; the brand lives in the app, and on the keyboard only in
  the two tints and the input corner (`radius/input`) of the field and the
  chip. The brand's radii hold everywhere else.
- SF Symbols for every glyph (the web uses Material Symbols): the platform's,
  on the mic key as on the app's screens.

## Next

Onboarding as a stepped flow once sign-in exists; the app's cues on the
phase edges; the classic profile measured, and the parity run on it, once an
iOS 18 runtime installs; `tokens.json` pruned of the hand-drawn keyboard's
rows. Autocorrect, the suggestion bar, the emoji keyboard and the other
locales are KeyboardKit Pro and out of scope: the free core only.
