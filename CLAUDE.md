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
also skips Swift lint — so on the web, Swift formatting and lint stay a CI concern.

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

## Permissions

`.claude/settings.json` pre-allows the read-only and verification commands this repo needs
(`swift test`, `swift build`, `xcodegen generate`, the Debug `xcodebuild` invocation, the linters,
`scripts/check.sh` with and without `--portable`, `scripts/dev-build.sh`). If you find yourself
prompted for a command that belongs in that set, add it there rather than working around it.
