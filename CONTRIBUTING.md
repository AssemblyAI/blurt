# Contributing to Blurt

Thanks for taking a look. Blurt is a small, open-source macOS dictation app, and
contributions of all sizes are welcome — bug reports, fixes, docs, or a new idea.

## Before you start

Blurt is **macOS-only** (macOS 15+, Apple Silicon, AppKit + AVFoundation). You
need a Mac with Xcode 16+ to build, test, or run it. On Linux you can still read
and edit the Swift source, but you can't build or verify it locally — CI on
`macos-26` is the authority on green.

[`AGENTS.md`](./AGENTS.md) is the canonical guide to how the code is laid out —
the engine package, the AppKit shell, the dictation pipeline, and the
intentional design decisions behind them. Read it before a non-trivial change so
you don't reintroduce something that was deliberately removed.

## Dev workflow

```bash
scripts/bootstrap.sh        # install the local toolchain on a fresh Mac
scripts/dev-build.sh        # signed Debug build + install to /Applications
swift test                  # engine unit tests (Swift Testing)
scripts/check.sh            # full health check — the same script CI runs
```

`scripts/check.sh` is the source of truth for "is this green?" It runs the
tests (warnings-as-errors), the coverage gate, the sanitizer passes, an xcodegen
drift check, the app build, and the full lint suite (swift-format, swiftlint,
prettier, markdownlint, and friends). Run it before you open a pull request — if
it's clean locally, it'll be clean in CI.

If you install the git hooks, `check.sh` runs automatically on every commit.

## Pull requests

- Branch off `main` and keep each PR focused on one thing.
- Make sure `scripts/check.sh` passes (or, if you're on Linux, say so in the PR
  and let CI verify).
- Match the surrounding code: 2-space indent, Swift Testing for tests, no new
  external dependencies in the engine.
- Write a clear description of what changed and why.

## Reporting bugs and ideas

Open an [issue](https://github.com/alexkroman/blurt/issues) using one of the
templates. For bugs, include your macOS version and steps to reproduce. For a
security issue, don't open a public issue — see [`SECURITY.md`](./SECURITY.md).

By contributing, you agree your work is licensed under the repo's
[MIT License](./LICENSE).
