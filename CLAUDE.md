# CLAUDE.md

This repository's canonical agent instructions live in [`AGENTS.md`](./AGENTS.md) — read that first.
It is tool-agnostic and covers the repository map, the settled decisions you must not reintroduce,
the conventions, and how to verify a change. How each part of the pipeline and the app shell works
lives in [`ARCHITECTURE.md`](./ARCHITECTURE.md): don't read it front to back — open the section for
the code you are about to change (`AGENTS.md`'s "Architecture reference" indexes it).

## Getting a PR to green fast

A `check.yml` run takes ~37 minutes, so the time to merge is mostly the number of runs a PR needs.

1. **Run `scripts/check.sh --portable` before every push, Swift changes included.** It catches jscpd
   (copy/paste), invariant, shell, workflow and Markdown failures that otherwise cost a CI run. On a
   Mac, `scripts/check.sh --lint-only` adds swift-format, `swiftlint lint` and design-sync in
   minutes.
2. **Know what only CI checks from a web sandbox**: `swiftlint lint` (not installed here — read
   `.swiftlint.yml` before writing Swift), periphery (a property assigned but never read is the
   usual catch), `scripts/design-sync.sh --check` (after touching `App/BlurtiOS/Design/tokens.json`
   or a keyboard view), swift-format, the build and every test.
3. **Watch the `lint` job first.** It runs `check.sh --lint-only` and turns red in minutes; `macos`
   runs the same checks but reports them only at the end of its build and tests.
4. **Push once per batch.** Each push cancels the run in progress and restarts the clock. When a run
   goes red, fix everything it names — apply the `swift-format-patch` artifact rather than guessing
   at a reflow — then push.

`AGENTS.md` › Verifying your work › Working without a macOS toolchain has the same rules in
tool-agnostic form.

This file adds only what is specific to Claude Code: the tooling wired up under `.claude/`.

## Hooks (`.claude/settings.json`)

| Hook                                | What it does                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SessionStart` → `session-start.sh` | Web/Linux sandboxes only (`CLAUDE_CODE_REMOTE=true`): installs the portable linters so `scripts/check.sh --portable` works, then prints a preflight noting CI is the authority on green. SwiftLint and swift-format are _not_ installed — their Linux builds ship as GitHub release binaries, which the default network policy blocks. Local macOS sessions exit immediately. |
| `PreToolUse` → `protect-pbxproj.sh` | Blocks edits to `App/Blurt/Blurt.xcodeproj/project.pbxproj` (exit 2). Edit `App/Blurt/project.yml` and run `xcodegen generate` instead. (The iPhone project, `App/BlurtiOS/BlurtiOS.xcodeproj`, isn't committed at all: edit `App/BlurtiOS/project.yml`; every script regenerates it.)                                                                                        |
| `PostToolUse` → `swift-format.sh`   | Formats every edited `*.swift` file with the repo's `.swift-format` config, so edits are CI-clean by construction. No-ops when the tool is absent.                                                                                                                                                                                                                            |
| `PostToolUse` → `swiftlint.sh`      | Lints edited Swift files and surfaces violations immediately rather than at `check.sh` time.                                                                                                                                                                                                                                                                                  |
| `PostToolUse` → `swift-budgets.sh`  | Runs `check-swift-size.sh` (SwiftLint's file and type-body length limits) and, for test files, `check-test-clock.sh` (a wall-clock wait must say why) on the edited file. Needs no toolchain, so unlike the two hooks above it works in the web sandbox, where those limits otherwise surfaced only on CI.                                                                    |

The `swift-format` and `swiftlint` hooks are silent no-ops off-Mac, which is exactly when
`check.sh --portable` also skips Swift lint — so on the web, Swift formatting and lint are otherwise
a pure CI concern.
`check.yml`'s `format-patch` job softens that: it runs `swift-format` for real on every PR and
publishes the resulting diff as a job summary and a `swift-format-patch` artifact, so the fix is
`git apply` rather than a blind reflow.

`.claude/hooks/swift-line-length.sh` narrows that gap: line width is the one `.swift-format` rule
checkable with no toolchain, so it flags over-long lines (reading the limit from `.swift-format`) and
stays quiet whenever `swift-format` is present and about to reflow the file anyway. It is
**deliberately not registered** in `settings.json`, so it never runs as shipped — enable it by adding
a fourth `PostToolUse` entry beside the other three:

```json
{
  "type": "command",
  "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/swift-line-length.sh"
}
```

It is no substitute for `swift-format`: indentation, wrapping, and every other rule still need the
real tool, and `swift-format lint --strict` on CI remains the authority.

`check.sh`'s shellcheck step covers `.claude/hooks/*.sh` as well as `scripts/*.sh` — the hooks run on
every edit, so a quoting bug there corrupts a source file rather than merely failing a build. The
repo-root `.shellcheckrc` (`external-sources` plus two `source-path`s) resolves the `source` lines
however shellcheck is run, so linting one script alone is as clean as `check.sh`'s run over all of
them — no SC1091 for a library that isn't on the command line. (`shfmt` still covers only
`scripts/*.sh`.)

## Hookify rules (`.claude/hookify.*.local.md`)

Warn-only rules for the [hookify](https://github.com/anthropics/claude-plugins-official) plugin,
each from a mistake that cost real time. They need hookify installed and do nothing without it. They
keep hookify's `.local.md` suffix — the only name it loads — and `.gitignore` opts them back in.

| Rule                          | Fires on                                                  | Why                                                                                                       |
| ----------------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `warn-zsh-unsplit-vars`       | `for x in $VAR;` / `git checkout … $VAR`                  | zsh doesn't word-split `$VAR`: a resolve committed conflict markers, and a cleanup loop deleted nothing   |
| `warn-swift-edited-via-shell` | `sed -i` / python `write_text` / `>` into a `.swift` file | the swift-format and swiftlint hooks fire only on Edit/Write, so the file goes unformatted to CI          |
| `warn-blind-ours-theirs`      | `git checkout --ours` / `--theirs`                        | keeping one side whole can drop another PR's change to the same file — check what else landed on it first |

## Skills (`.claude/skills/`)

- **`check`** — how to decide whether the repo is green, including the macOS-only guard and the
  portable subset. Load it before claiming a change builds or passes.
- **`project-guardrails`** — the compressed "don't do this" list. `AGENTS.md`'s
  [Settled decisions](./AGENTS.md#settled-decisions--dont-reintroduce-these) table is the fuller
  reference and the source of truth; keep the two in agreement when you change either. For the
  decisions `scripts/check-invariants.sh` mechanizes, that agreement is no longer on your
  honour: each rule pins a verbatim slice of its table row _and_ its skill bullet, so deleting or
  rewording either fails the gate's `--self-test` until someone decides whether the rule survives
  the edit. The rest of the list is still yours to keep in sync.
- **`release`** — the ship pipeline (build → sign → notarize → staple → DMG → GitHub). User-invoked
  only: it has real, hard-to-undo side effects.
- **`launch-metrics`** — read-only launch KPI snapshot from the GitHub API.

## Subagents (`.claude/agents/`)

- **`swift6-concurrency-reviewer`** — run after editing engine, Mac app or iPhone code that
  touches actors, async, the mic capture path, the dictation pipeline, or the keyboard's hand-off
  with the iPhone app (`BlurtiOSCore`'s model, `DictationCoordinator`, `ListeningWindow`).
- **`macos-hig-reviewer`** — run after editing views in `App/Blurt/` (wizard, settings, overlay).
  Mac only: the iPhone's keyboard is Apple's (KeyboardKit) and answers to the parity probe
  (`scripts/keyboard-parity.sh`) and the probe's screenshots (`scripts/ios-keyboard-shot.sh`).
- **`cleanup-reviewer`** — quality-only review (reuse, simplification/dead code, efficiency,
  altitude), one agent per angle. Use it for `/simplify`-style passes instead of writing the
  guardrails into an ad-hoc prompt: it loads `project-guardrails` itself and already knows the
  deliberately-dormant code.

**When you spawn a review subagent, have it invoke the `project-guardrails` skill rather than
restating the settled decisions in the prompt** — the skill is exactly that list, so a hand-written
copy is both wasted tokens and a chance to leave something out. This matters most on a dead-code or
simplification pass, which is precisely when an unbriefed agent proposes deleting the
`TranscriptionContext` fields the prompt deliberately ignores but the paste path and the
developer-mode log rely on.

## Running locally

When someone asks how to run, build, or test Blurt locally, answer with the supplied scripts —
not raw `brew install` or hand-rolled `xcodebuild` invocations:

1. `scripts/bootstrap.sh` — one-time: `brew bundle` installs every Homebrew-managed dependency
   from `Brewfile` (Homebrew itself must already be installed).
2. `scripts/dev-build.sh` — the everyday loop: clean signed `Debug-Local` build, installed to
   `/Applications` as "Blurt Dev".
3. `open -a "Blurt Dev"` — run it.

[`CONTRIBUTING.md`](./CONTRIBUTING.md#local-setup) covers the prerequisites (Apple Silicon Mac,
full Xcode — not just the Command Line Tools, Homebrew, a free Apple Development certificate)
and why the scripts work the way they do.

For the iPhone app (`App/BlurtiOS`, the keyboard included), from the repo root:

1. `xcodebuild -downloadPlatform iOS` — one-time: the simulator runtime **matching this Xcode's
   iOS SDK**. An older runtime is refused at the destination ("iOS 26.5 is not installed"), even
   with simulators for it listed.
2. `scripts/ios-sim.sh` — build, boot a simulator, install, grant the microphone, launch.
   `BLURT_SIM_DEVICE="iPhone Air"` picks one; avoid the one a test run is using.
3. In the simulator: Settings › Apps › Blurt › Keyboards (or General › Keyboard › Keyboards ›
   Add New Keyboard) — Blurt on, Allow Full Access; then **Start listening** in Blurt.

The simulator records through the Mac's microphone (`SimulatorAudioSource`), so dictation also
needs macOS to allow the **Simulator** app the microphone (Privacy & Security › Microphone) and
the right input under the Simulator's I/O › Audio Input — a refused microphone records silence
rather than failing. `scripts/ios-check.sh` runs the iPhone's quality gates (tests with the
`BlurtiOSCore` coverage floor, the accessibility audits (`scripts/ios-uitest.sh`), `swiftlint
analyze`, periphery, the probe build); `check.sh` runs it
itself when this Mac has the matching runtime.

## Permissions

`.claude/settings.json` pre-allows the read-only and verification commands this repo needs
(`swift test`, `swift build`, `xcodegen generate`, the Debug `xcodebuild` invocation, the linters,
`scripts/check.sh` with and without `--portable` or `--lint-only`, the standalone checks it runs
(`check-invariants.sh`, `check-portability.sh`, `check-release-notes.sh`, `design-sync.sh --check`,
`mutate.sh --list`), `scripts/dev-build.sh`, and the iPhone scripts:
`ios-sim.sh`, `ios-test.sh`, `ios-check.sh`, `ios-typecheck.sh`, `ios-uitest.sh`, and the split-out
static gates, `swiftlint-analyze.sh` and `mac-static.sh`). If you find yourself
prompted for a command that belongs in that set, add it there rather than working around it.
