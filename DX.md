# Where the rework comes from, and what to change

An audit of all 125 closed PRs (127 pushed branches) in this repo, looking for the ones that took
the most commits to land and why. Comment counts are near-zero across the board — this is a solo,
agent-driven repo — so "struggle" shows up as **commit churn and repeated red CI runs**, not
discussion. Every claim below cites the commits or CI runs it came from.

## The headline

**CI is the only compiler and the only formatter, and it reports one problem at a time.**

The web sandbox has no Swift toolchain (verified: `download.swift.org` is unreachable under the
default network policy, GitHub's release API returns 403; only npm, pip, the Go module proxy,
`git clone`, and raw.githubusercontent are open — so no Linux Swift build is obtainable, and
`swift-format`/SwiftLint/periphery genuinely cannot run locally). Every Swift mistake therefore
costs a full push → CI → read-log → fix → push cycle. Median green `check` run: **11.3 min**;
median red run: **5.3 min**; **10 of the last 26 completed runs were red**.

Worse, `check.sh` runs its checks cheapest-last: `swift test` (line 265), the TSan pass (298), the
ASan pass (311), `xcodegen` drift (318), the app build (335), XCUITest (394), leaks (400) — and only
_then_ `swift-format` (427) and `swiftlint lint` (435). A compile error means the mechanical
findings are never even reached, so they arrive on the _next_ run, one at a time. PR #80 says this
out loud: "Fix the three SwiftLint violations **behind the earlier failures**".

## The six rework classes

| #   | Class                                                            | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                           | Commits   |
| --- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| A   | Swift/test **compile** errors first caught by CI                 | #124 three consecutive red runs (`#expect` on a throwing `allSatisfy`, then `signingInformation()`, then the UI-test carve-out); #122 three more (`$0` shadowing, `internal(set)`, missing `import Foundation` for `pid_t`); #118 "`#expect` can't call a mutating method"                                                                                                                                                                         | ~9        |
| B   | **Formatting/lint** findings first caught by CI                  | #80 (file-length split, "stray blank line swift-format flagged", "three SwiftLint violations behind the earlier failures", "two periphery breakers"); #118 (`WaveformMeter` call chain, unused `Foundation` import); #113; #98                                                                                                                                                                                                                     | ~10       |
| C   | Hand-merging `main` into long-lived branches                     | 12 merge commits; #118 merged twice (its own message: "second time"); #124 twice. Each merge buys a fresh 11-minute run, and inflates the PR diff — #124 shows 133 files for a ~10-file change                                                                                                                                                                                                                                                     | 12        |
| D   | GNU-sandbox vs BSD-CI divergence                                 | #116 "Fix the sitemap `<loc>` strip on BSD sed (macOS CI)" — shellcheck does not flag this                                                                                                                                                                                                                                                                                                                                                         | 1         |
| E   | Approach built, hardened, then reverted                          | #116 adopted `html-proofer` (2 commits), enabled every check (2 more), then "Drop html-proofer — GPL in the dependency tree — back to no dependencies"                                                                                                                                                                                                                                                                                             | ~5        |
| F   | A hard constraint asked for in prose instead of enforced in code | #110 (40 commits, the largest PR in the repo) spends ~8 on one character cap: "Make the character cap something the search obeys" → "Lean much harder on the length limit, **because asking politely does not work**" → "Aim the reflector below the cap, **because it hits what it aims at**" → "State the budget as a target with a ceiling, and again as a shape" → "Fall back to the service default rather than send an over-cap instruction" | ~8        |
| G   | Duplicate / superseded PRs and reused branches                   | `claude/sign-publish-gh-workflow-d9h2oa` backed **three** PRs (#109, #120, #123); #90 and #91 have identical titles; #101 and #120 are both "chore: release v0.1.36"; #102 reverts the app to v0.1.34                                                                                                                                                                                                                                              | whole PRs |

Churn leaders: **#110** (40 commits), #73 (29), #80 (25), #124 (23), #118 (23), #116 (19), #123 (14).
And **29 of 127 branches touch release/signing/workflow machinery** — the chronic sink.

## Fixes, ranked by rework removed per unit of work

### 1. Reorder `check.sh`: mechanical checks before the multi-minute ones

Move `swift-format lint`, `swiftlint lint --strict`, and the portable linters **above** `swift test`.
They are source-only and take seconds. `swiftlint analyze` (needs the app build log) and `periphery`
(does its own build) must stay where they are.

Cost: moving two blocks. Green runs cost exactly the same. Every class-B finding arrives in the
_first_ red run instead of the second or third, and it arrives ~10 minutes sooner. This alone
collapses the #80 and #124 sequences.

### 2. Let CI fix formatting instead of failing on it

A `format` job on `pull_request` that runs `swift-format format --in-place --recursive` (plus
`swiftlint --fix`) and, when the tree comes back dirty, pushes a `style:` commit to the PR head.
Split in two to honor the rule check.yml already documents — never hold a writable token in a job
that built PR code: the build job stays `contents: read` and uploads the patch, a second job with
`contents: write` and no checkout of build output applies it.

If auto-push is unwanted, the cheaper half still pays: publish `format.patch` as an artifact and
render it into `$GITHUB_STEP_SUMMARY`, so the fix is one `git apply` rather than a guess. Note that
`swiftlint lint` correctness findings and periphery findings are _not_ auto-fixable — leave those red.

Removes class B (~10 commits) permanently, for every author.

### 3. A fast-fail compile job

Add a `compile` job: `swift build --build-tests -Xswiftc -warnings-as-errors` and nothing else — no
test execution, no sanitizers, no coverage, no xcodegen, no app build. Run it in parallel with
`check` and make `dev-build` `needs: compile`.

Class-A errors then surface in ~2 minutes instead of 5–12, and a PR whose tests don't compile stops
paying for a second 30-minute-timeout macOS job to build it. Green PRs are not slowed. Worth pairing
with a `.build` cache keyed on `Package.resolved` — today every run compiles the engine from cold
four times (test, TSan, ASan, app).

### 4. Write down the Swift Testing traps

The same handful of mistakes recur because Swift is written blind here. Add a short subsection to
AGENTS.md's Tests section:

- `#expect` takes an autoclosure, so it **cannot call a `mutating` method** — bind to a `var` and
  assert the result (#118, #122).
- `#expect` around a `rethrows` call with a throwing argument needs `try` — `#expect(hex.allSatisfy(\.isHexDigit))`
  is the exact form that failed on run 31560770791; use `try #expect(...)` or hoist the value.
- A new test file needs its own `import Foundation` for `pid_t`, `Data`, `URL` (#122).
- Splitting a type across files means widening `private(set)` to `internal(set)` for the other half
  (#122), and `@testable` does not cross module boundaries.

Cheapest item on the list, and it targets the most expensive class.

### 5. A portability gate for GNU-vs-BSD shell

~20 lines in the portable subset flagging `sed -i` without a suffix, `grep -P`, `readlink -f`,
`stat -c`, `date -d`, `base64 -w`, `xargs -r`. Needs a `# portable-ok:` escape comment —
`release-lib.sh:91,195` uses `sort -V` deliberately and `release-bump.sh:47` correctly writes
`sed -i.bak`. Catches class D, which shellcheck cannot see.

### 6. Enable auto-merge; rebase instead of merging `main`

`merge_group` is already wired into check.yml, but the 12 merge commits show branches being
refreshed by hand. Convention: enable auto-merge on the PR and let the queue land it; merge `main`
only for a real conflict or a semantic dependency, and rebase when you do, so the PR diff stays the
change. Removes class C and shrinks review diffs by an order of magnitude.

### 7. One branch, one PR — a closed PR's branch is dead

Three PRs shared `claude/sign-publish-gh-workflow-d9h2oa`, and #90/#91 and #101/#120 are duplicate
pairs. Make it a stated repo convention, alongside a preference for small stacked PRs over reusing
a branch to carry follow-up work.

### 8. Settle the dependency licence policy before adopting anything

PR #116 built on `html-proofer`, hardened it, then deleted it for GPL-in-the-tree. Add the policy to
the settled-decisions table (permissive only — MIT/Apache-2.0/BSD; no GPL/AGPL anywhere in the
tree) with a one-line pre-adoption check (`npm view <pkg> license`, `gem dependency`). Converts a
five-commit round trip into a ten-second lookup.

### 9. Enforce eval constraints in the harness, not in the prompt

PR #110's lesson, stated as a rule in the evals README: **a hard bound on model output belongs in code
as reject/regenerate/truncate, never in the instruction text.** Validate candidates against the
character cap before they enter the search, so an over-cap candidate can never be scored. Eight
commits of "asking politely does not work" is the price of the alternative.

## Not worth doing

**Installing a Swift toolchain in the sandbox.** Verified unreachable — and even with
`download.swift.org` allowlisted, it would only buy formatting: the engine imports AVFoundation, so
Linux still cannot typecheck it, and building swift-syntax from a clone costs minutes on every cold
container. Fix #2 gets the same benefit for a fraction of the cost.

**Registering `.claude/hooks/swift-line-length.sh`.** Deliberately dormant per CLAUDE.md; line
length is one rule out of many, and fix #2 subsumes it.
