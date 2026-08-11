# Contributing to Blurt

Thanks for taking a look. Blurt is a small, open-source macOS dictation app, and
contributions of all sizes are welcome — bug reports, fixes, docs, or a new idea.

## Before you start

Blurt is **macOS-only** (Apple Silicon, AppKit + AVFoundation). You need a Mac
with Xcode to build, test, or run it — see [Local setup](#local-setup) below.
On Linux you can still read and edit the Swift source, but you can't build or
verify it locally; CI on `macos-26` is the authority on green.

[`AGENTS.md`](./AGENTS.md) is the canonical guide to how the code is laid out —
the engine package, the AppKit shell, the dictation pipeline, and the
intentional design decisions behind them. Read it before a non-trivial change so
you don't reintroduce something that was deliberately removed.

## Local setup

You'll need:

- An **Apple Silicon Mac** on macOS 15+ (26 recommended).
- **Xcode 26+** — the full app, not just the Command Line Tools.
  `xcode-select -p` should print a path inside `Xcode.app`; if it doesn't, run
  `sudo xcode-select -s /Applications/Xcode.app`.
- **[Homebrew](https://brew.sh)**, which `bootstrap.sh` uses to install
  everything else.
- An **[AssemblyAI API key](https://www.assemblyai.com/dashboard/api-keys)**
  (free tier is plenty) if you want to actually dictate with your build. Blurt's
  setup wizard asks for it on first launch and stores it in the Keychain.

Then:

```bash
git clone https://github.com/AssemblyAI/blurt.git
cd blurt
scripts/bootstrap.sh        # install the toolchain from Brewfile
scripts/dev-build.sh        # build Blurt and install it to /Applications
open -a Blurt
```

That's the whole setup. Everything else is one of these scripts:

| Script                        | What it does                                                                                                   |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `scripts/bootstrap.sh`        | `brew bundle` from `Brewfile` — xcodegen, swiftlint, prettier, shellcheck, markdownlint, periphery, xcbeautify |
| `scripts/dev-build.sh`        | Clean signed `Debug-Local` build, installed to `/Applications`. The everyday loop.                             |
| `scripts/check.sh`            | The full health check CI runs. The source of truth for "is this green?"                                        |
| `scripts/check.sh --portable` | Just the platform-independent subset (docs, site, scripts, workflows) — the part that runs off a Mac           |
| `swift test`                  | Engine unit tests only (Swift Testing), no app build                                                           |
| `scripts/uitest.sh`           | The XCUITest suite that drives the real app                                                                    |
| `scripts/leaks.sh`            | Whole-app leak check                                                                                           |

`dev-build.sh` installs to `/Applications` on purpose: macOS refuses to register
Accessibility and Input-Monitoring grants for an app living in a build
directory, so Blurt is unusable from DerivedData. It builds the `Debug-Local`
configuration — a debug build with the UI-test scaffolding compiled out, so it's
the real app.

### A note on signing

`dev-build.sh` signs with an **Apple Development** certificate from your login
keychain. Adding any Apple ID under Xcode → Settings → Accounts gets you one for
free. (The Developer ID release key is a different thing entirely and lives in a
separate, normally-locked keychain used only by releases — see
[`RELEASE.md`](./RELEASE.md).)

If you'd rather not set up a certificate, build ad-hoc signed instead:

```bash
xcodebuild -project App/Blurt/Blurt.xcodeproj -scheme Blurt \
  -configuration Debug-Local -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES build
```

That skips the `/Applications` install, and an ad-hoc signature changes on every
build — macOS keys the Accessibility grant to the signature, so you'd re-grant
permissions after each rebuild. Fine for checking that a change compiles and
launches; `dev-build.sh` is the better daily loop.

### After editing `App/Blurt/project.yml`

Run `xcodegen generate` and commit the regenerated `Blurt.xcodeproj/project.pbxproj`
alongside it. `check.sh` fails on drift between the two. Never hand-edit the
`.pbxproj` — it's generated.

### Working without a Mac

You can read and edit Swift, and `scripts/check.sh --portable` fully verifies
docs, site, script, and workflow changes. It skips the entire Swift side and
says so on its last line, so don't read a green portable run as "it builds" —
open the PR and let CI on `macos-26` answer that.

## Pull requests

- Branch off `main` and keep each PR focused on one thing.
- Make sure `scripts/check.sh` passes (or, if you're on Linux, say so in the PR
  and let CI verify).
- Match the surrounding code: 2-space indent, Swift Testing for tests, no new
  external dependencies in the engine.
- Write a clear description of what changed and why.

Every PR that touches code gets an **installable dev build**: CI builds
`Blurt.app` from your branch and a bot comments a download link, so a reviewer
can try the change rather than imagine it. The build is ad-hoc signed and not
notarized, so it needs its quarantine flag cleared — the comment spells out the
three commands.

## Reporting bugs and ideas

Open an [issue](https://github.com/AssemblyAI/blurt/issues) using one of the
templates. For bugs, include your macOS version and steps to reproduce. For a
security issue, don't open a public issue — see [`SECURITY.md`](./SECURITY.md).

By contributing, you agree your work is licensed under the repo's
[MIT License](./LICENSE).
