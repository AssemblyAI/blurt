# CLAUDE.md

This repository's canonical agent instructions live in [`AGENTS.md`](./AGENTS.md) — read that first.
It is tool-agnostic and covers the architecture, the settled decisions you must not reintroduce, the
conventions, and how to verify a change.

This file adds only what is specific to Claude Code: the tooling wired up under `.claude/`.

## Hooks (`.claude/settings.json`)

| Hook                                | What it does                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SessionStart` → `session-start.sh` | Web/Linux sandboxes only (`CLAUDE_CODE_REMOTE=true`): installs the portable linters so `scripts/check.sh --portable` works, then prints a preflight noting CI is the authority on green. SwiftLint and swift-format are _not_ installed — their Linux builds ship as GitHub release binaries, which the default network policy blocks. Local macOS sessions exit immediately. |
| `PreToolUse` → `protect-pbxproj.sh` | Blocks edits to `App/Blurt/Blurt.xcodeproj/project.pbxproj` (exit 2). Edit `App/Blurt/project.yml` and run `xcodegen generate` instead.                                                                                                                                                                                                                                       |
| `PostToolUse` → `swift-format.sh`   | Formats every edited `*.swift` file with the repo's `.swift-format` config, so edits are CI-clean by construction. No-ops when the tool is absent.                                                                                                                                                                                                                            |
| `PostToolUse` → `swiftlint.sh`      | Lints edited Swift files and surfaces violations immediately rather than at `check.sh` time.                                                                                                                                                                                                                                                                                  |

The two `PostToolUse` hooks are silent no-ops off-Mac, which is exactly when `check.sh --portable`
also skips Swift lint — so on the web, Swift formatting and lint are otherwise a pure CI concern.
`check.yml`'s `format-patch` job softens that: it runs `swift-format` for real on every PR and
publishes the resulting diff as a job summary and a `swift-format-patch` artifact, so the fix is
`git apply` rather than a blind reflow.

`.claude/hooks/swift-line-length.sh` narrows that gap: line width is the one `.swift-format` rule
checkable with no toolchain, so it flags over-long lines (reading the limit from `.swift-format`) and
stays quiet whenever `swift-format` is present and about to reflow the file anyway. It is
**deliberately not registered** in `settings.json`, so it never runs as shipped — enable it by adding
a third `PostToolUse` entry beside the other two:

```json
{
  "type": "command",
  "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/swift-line-length.sh"
}
```

It is no substitute for `swift-format`: indentation, wrapping, and every other rule still need the
real tool, and `swift-format lint --strict` on CI remains the authority.

`check.sh`'s shellcheck step covers `.claude/hooks/*.sh` as well as `scripts/*.sh` — the hooks run on
every edit, so a quoting bug there corrupts a source file rather than merely failing a build. Both
globs go in one invocation so `hook-lib.sh` and `release-lib.sh` are in the input set and the
`source` lines resolve instead of raising SC1091. (`shfmt` still covers only `scripts/*.sh`.)

## Skills (`.claude/skills/`)

- **`check`** — how to decide whether the repo is green, including the macOS-only guard and the
  portable subset. Load it before claiming a change builds or passes.
- **`project-guardrails`** — the compressed "don't do this" list. `AGENTS.md`'s
  [Settled decisions](./AGENTS.md#settled-decisions--dont-reintroduce-these) table is the fuller
  reference and the source of truth; keep the two in agreement when you change either.
- **`release`** — the ship pipeline (build → sign → notarize → staple → DMG → GitHub). User-invoked
  only: it has real, hard-to-undo side effects.
- **`launch-metrics`** — read-only launch KPI snapshot from the GitHub API.

## Subagents (`.claude/agents/`)

- **`swift6-concurrency-reviewer`** — run after editing engine or app code that touches actors,
  async, the mic capture path, or the dictation pipeline.
- **`macos-hig-reviewer`** — run after editing views in `App/Blurt/` (wizard, settings, overlay).
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

## Permissions

`.claude/settings.json` pre-allows the read-only and verification commands this repo needs
(`swift test`, `swift build`, `xcodegen generate`, the Debug `xcodebuild` invocation, the linters,
`scripts/check.sh` with and without `--portable`, `scripts/dev-build.sh`). If you find yourself
prompted for a command that belongs in that set, add it there rather than working around it.
