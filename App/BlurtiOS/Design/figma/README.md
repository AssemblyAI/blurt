# The Blurt Keyboard Figma file, from scripts

The Figma file is built from these scripts, so the scripts — not the file — are
the durable record: a fresh file can be rebuilt in minutes, and the export back
(`tokens.json`) is what the app compiles. `DESIGN.md › Figma` has the loop.

| File            | What                                                                                                                                                 |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tokens.js`     | **Generated** from `../tokens.json` by `scripts/design-tokens.swift`: every token, alias, scope, iOS code syntax.                                    |
| `lib.js`        | The builders, plain Plugin API: `buildFoundations`, `buildComponents`, `buildLayouts`, `themeSheet`, `exportTokens`, `exportBounds`, `measureApple`. |
| `plugin.js`     | The development-plugin entry that dispatches `manifest.json`'s menu to those builders.                                                               |
| `manifest.json` | The plugin's manifest. `scripts/design-sync.sh` bundles all three JS files into `.build/figma-plugin/code.js`.                                       |

## Two ways to run the same code

**Through the Figma MCP (`use_figma`)** — the agent loads the `figma-use` skill
(and `figma-generate-library` for foundations and components,
`figma-generate-design` for layouts), then sends one call per builder whose
script is `tokens.js` + `lib.js` + one line:

```js
return await buildFoundations();
```

Calls are strictly sequential, every builder is idempotent (it finds by name
before it creates), and every call returns ids and counts. The connector must
be authenticated to the account that owns the file with an editing seat — Neil's
personal Figma, not the AssemblyAI org View seat (6 reads a month, no edits).

**As a development plugin** (no MCP quota at all): `scripts/design-sync.sh`
writes `.build/figma-plugin/{manifest.json,code.js}`; in Figma desktop,
Plugins → Development → Import plugin from manifest…, then run the menu items
in order. Results print to the plugin console (Plugins → Development → Open console).

## Order

1. `buildFoundations` — the six one-mode collections (`Brand`, `Themes`,
   `Keyboard`, `Metrics`, `Typography`, `Motion`) with scopes and iOS code syntax;
   aliases (`Themes` → `Brand`, `Keyboard` → `Themes`/`Brand`); the five text
   styles and `Shadow/Popup`; colour swatches and a token list on `01 Foundations`.
   Needs SF Pro installed on the Mac running Figma — it stops if the font is missing.
2. Place the orb stills, if you want real orbs rather than the brand gradient
   stand-in: `BLURT_LAUNCH_ARGS="-BlurtOrb 96 idle" scripts/ios-sim.sh --screenshot raw.png`
   then `swift scripts/design-diff.swift crop raw.png orb-96-idle.png`, for each of
   `40 96 112` × `off idle listening working landed`; upload them into the file
   (`upload_assets`, or drag them in) and name each node `orb-still/<Size>-<Mood>`
   (`orb-still/Panel-Idle`) on `02 Components`. `buildComponents` picks them up.
3. `buildComponents` — `Key`, `LetterKey`, `AddTermKey`, `CancelKey`, `TermField`,
   `Orb/Ring`, `Orb/Disc`, `WaveformMeter`, `MicKey`, `VoiceBar` on `02 Components`,
   every fill, stroke, radius and gap bound to a variable. Re-running replaces a set in place.
4. `buildLayouts` — `03 Layouts`: sections `Panel`, `SlimBar`, `Full`, each a
   column of frames named `<layout>/<state>/ink` exactly as the gallery captions
   them, 402 pt wide (iPhone 18 Pro, the capture device). Re-running rebuilds the sections.
5. `themeSheet` — re-aliases `kb/*` to each theme in turn, exports the idle
   frames at 3× and places them as images in a `Theme sheet` section, then
   restores `ink`. This is `KeyboardPalette.resolve(_:dark:)` in Figma; a
   Starter file has one variable mode, so themes are value sets, not modes.
6. Paste the Apple `Keyboard` instances (light and dark, iPhone) from the
   "iOS and iPadOS 27" kit into a section named `Apple reference` on `03 Layouts`,
   lock them, and run `measureApple` — the numbers go into DESIGN.md's Apple geometry table.
7. After a design pass: `exportTokens` → merge its `tokens` object into
   `../tokens.json` (keep `gradients` and `figma`) → `scripts/design-sync.sh` →
   the views. `exportBounds` gives every named node's rectangle per layout frame
   for `scripts/design-diff.swift`'s colour and geometry gates.

The first run against a real file will surface Plugin API details these scripts
could not be tested against (they were written before the file existed); fix the
builder, re-run it — nothing here is precious except `tokens.json`.
