#!/bin/bash
# The SwiftLint and swift-format rules that cost CI runs, checked without either.
#
# Neither tool has a build the web sandbox can fetch, so a violation of one of
# their rules surfaced only on CI, ~37 minutes after the push — and once #392
# turned on every opt-in rule, a single-line fix-up commit per rule became the
# most common follow-up after the size budgets (check-swift-size.sh). Each rule
# below is one a recent PR spent a run on, and is narrow enough to match by text
# with no false positive in the tree:
#
#   modifier_order   `public nonisolated` → `nonisolated public` (#422). Only the
#                    five classic access levels: SwiftLint accepts
#                    `package nonisolated`, which BlurtDesign spells throughout.
#   no_empty_block   `{}` or `{ }` as a closure or function body (#414). A type's
#                    empty body (`struct Boom: Error {}`) is allowed. The fix is a
#                    line comment inside — not a block comment, which:
#   NoBlockComments  swift-format rejects `/* … */` in code (#414). Doc comments
#                    that mention a glob (`key/*`) are comments, not code.
#   catch-where      swift-format lays a patternless `catch where` out with two
#                    spaces, `catch  where` (#425), and its lint fails one.
#
# Comments and string literals are stripped before matching, so prose and JSON
# fixtures ("{}") don't count. The rules SwiftLint applies that text can't see —
# variable_shadowing, one_declaration_per_file, type_contents_order,
# multiline_function_chains, redeclaration, MemberImportVisibility — are listed in
# CLAUDE.md › "Rules only CI catches" instead.
#
# Usage:
#   check-swift-lint-lite.sh               every tracked Swift file SwiftLint lints
#   check-swift-lint-lite.sh FILE...       just these (the PostToolUse hook's mode)
#   check-swift-lint-lite.sh --self-test   the rules against known inputs
#
# Exit 1 on any finding.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# SwiftLint's `included` paths; check-swift-size.sh's self-test pins the same list
# to .swiftlint.yml.
INCLUDED=(Sources Tests App/Blurt/Blurt App/Blurt/BlurtUITests App/BlurtiOS)

# Prints "path:line: rule: message" per finding; exit 1 if any.
scan() {
  python3 - "$@" <<'PY'
import re
import sys

RULES = [
    (
        "modifier_order",
        re.compile(r"\b(public|private|fileprivate|internal|open)(\(set\))?\s+nonisolated\b"),
        "put `nonisolated` before the access level (`nonisolated public let`)",
    ),
    (
        "no_empty_block",
        re.compile(
            r"(?:[:(,=]|\)|->\s*[\w.?!\[\]<>]+|\b(?:else|do|defer|catch))\s*\{\s*\}"
            r"|\{\s*\w+(?:\s*,\s*\w+)*\s+in\s*\}"
        ),
        "an empty block: put a `// line comment` inside saying why it does nothing",
    ),
    (
        "NoBlockComments",
        re.compile(r"/\*"),
        "swift-format rejects block comments: use `//` lines",
    ),
    (
        "catch-where",
        re.compile(r"\bcatch where\b"),
        "swift-format spells a patternless catch-where with two spaces: `catch  where`",
    ),
]


def code_lines(text):
    """Yield (line number, code) with strings blanked and `//` comments removed.

    A `/*` is kept in the code so NoBlockComments can see it; the rest of a block
    comment is dropped.
    """
    in_block = False
    in_multi = False
    for number, raw in enumerate(text.split("\n"), 1):
        code = []
        i = 0
        n = len(raw)
        while i < n:
            if in_block:
                end = raw.find("*/", i)
                if end < 0:
                    i = n
                    break
                i = end + 2
                in_block = False
                continue
            if in_multi:
                end = raw.find('"""', i)
                if end < 0:
                    i = n
                    break
                i = end + 3
                in_multi = False
                code.append('""')
                continue
            if raw.startswith("//", i):
                break
            if raw.startswith("/*", i):
                code.append("/*")
                in_block = True
                i += 2
                continue
            if raw.startswith('"""', i):
                in_multi = True
                i += 3
                continue
            if raw[i] == '"':
                j = i + 1
                while j < n and raw[j] != '"':
                    j += 2 if raw[j] == "\\" else 1
                code.append('""')
                i = j + 1
                continue
            code.append(raw[i])
            i += 1
        yield number, "".join(code)


found = False
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        continue  # a tracked file deleted from the working tree
    for number, code in code_lines(text):
        for rule, pattern, message in RULES:
            if pattern.search(code):
                print(f"{path}:{number}: {rule}: {message}")
                print(f"    {code.strip()}")
                found = True
sys.exit(1 if found else 0)
PY
}

self_test() {
  local dir failed=0
  dir="$(mktemp -d "${TMPDIR:-/tmp}/swift-lint-lite.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: $dir is local
  trap "rm -rf '$dir'" RETURN

  cat >"$dir/Clean.swift" <<'SWIFT'
/// Mentions `key/*` tokens and an empty `{}` in prose.
struct Boom: Error {}
enum Namespace {}
package nonisolated static let accent = 1
nonisolated public let turns = 2
let json = "{}"
let fixture = """
  /* not a comment */ { }
  """
func work() {
  do {
    try run()
  } catch  where error.isAbandonment {
    // A cancellation: nothing to report.
  }
  let step = {
    // No defaults to clear in a test.
  }
}
SWIFT
  if scan "$dir/Clean.swift" >/dev/null; then
    echo "  ok   a clean file passes (prose, strings, type bodies, package nonisolated)"
  else
    echo "  FAIL a clean file was flagged:" >&2
    scan "$dir/Clean.swift" | sed 's/^/         /' >&2 || true
    failed=1
  fi

  local rule line
  while IFS='|' read -r rule line; do
    printf '%s\n' "$line" >"$dir/Bad.swift"
    # Captured first: under pipefail, scan's exit 1 would fail a `scan | grep` pipe.
    if grep -q ": $rule: " <<<"$(scan "$dir/Bad.swift" || true)"; then
      echo "  ok   $rule: $line"
    else
      echo "  FAIL $rule missed: $line" >&2
      failed=1
    fi
  done <<'CASES'
modifier_order|  public nonisolated let turns: AsyncStream<Int>
modifier_order|  private(set) nonisolated var count = 0
no_empty_block|    clearSettings: {},
no_empty_block|  func noop() { }
no_empty_block|  init() {}
no_empty_block|  func value() -> Int? {}
no_empty_block|    } catch {}
no_empty_block|    items.forEach { _ in }
NoBlockComments|      clearSettings: { /* nothing */ },
catch-where|    } catch where !error.isAbandonment {
CASES
  return "$failed"
}

case "${1:-}" in
  --self-test) self_test ;;
  "")
    # Every tracked file SwiftLint lints. xargs, not an array: one scan per batch.
    cd "$REPO_ROOT"
    if git ls-files -z -- "${INCLUDED[@]/%//*.swift}" | xargs -0 bash "$0" --scan; then
      echo "no lint-lite findings (modifier_order, no_empty_block, NoBlockComments, catch-where)"
    else
      exit 1
    fi
    ;;
  --scan)
    shift
    scan "$@"
    ;;
  *)
    scan "$@" || {
      echo "       SwiftLint/swift-format would fail CI on these; fix them before pushing." >&2
      exit 1
    }
    ;;
esac
