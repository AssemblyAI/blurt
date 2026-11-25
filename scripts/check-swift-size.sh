#!/bin/bash
# SwiftLint's two size budgets, counted without SwiftLint.
#
# `file_length` (400 lines) and `type_body_length` (250 body lines) are default
# warnings that `swiftlint lint --strict` turns into failures. They were the most
# common reason a PR needed another ~37-minute CI run: #358, #363, #364, #368,
# #378 and #380 each pushed a follow-up commit only to split a file or a suite —
# twice because two PRs that each fit merged into one that didn't (#363 + #357,
# #378 + #365). SwiftLint has no Linux build the web sandbox can fetch, so until
# now nothing saw either budget before CI. A line count needs no toolchain.
#
#   file_length       exact: wc -l against SwiftLint's limit. A file carrying
#                     `swiftlint:disable file_length` is skipped, as SwiftLint does.
#   type_body_length  an estimate: non-blank, non-comment lines strictly inside a
#                     class/struct/enum/actor body (SwiftLint's default excludes
#                     extensions and protocols). Braces inside string literals
#                     and comments are ignored. Close to SwiftLint's count, not
#                     identical, so it fails only past the limit and warns early.
#
# Headroom: a file or type within HEADROOM of its limit is reported as a note,
# not a failure. That is the state where a parallel PR growing the same file
# tips the merged result over — the case a per-PR check can't see.
#
# Usage:
#   check-swift-size.sh               every tracked Swift file SwiftLint lints
#   check-swift-size.sh FILE...       just these (the PostToolUse hook's mode)
#   check-swift-size.sh --self-test   the counter against known inputs
#
# Exit 1 on any file or type over its limit; notes alone exit 0.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FILE_LIMIT=400
TYPE_LIMIT=250
HEADROOM="${BLURT_SIZE_HEADROOM:-20}"

# SwiftLint's `included` paths in .swiftlint.yml. Kept literal rather than parsed:
# the YAML is small, and a parse that silently returned nothing would read as a
# clean tree. The self-test asserts the list still matches the config.
INCLUDED=(Sources Tests App/Blurt/Blurt App/Blurt/BlurtUITests App/BlurtiOS)

# Prints "path<TAB>kind<TAB>name<TAB>count<TAB>line" per measured unit:
# kind is `file` or `type`. Pure awk, so GNU and BSD both run it.
measure() {
  awk '
    function report(kind, name, count, line) {
      printf "%s\t%s\t%s\t%d\t%d\n", cur, kind, name, count, line
    }
    # The file total is reported when the next file starts, so it carries the name of
    # the finished file (`cur`), not the new FILENAME.
    FNR == 1 {
      if (NR > 1) finish()
      cur = FILENAME
      depth = 0; sp = 0; pending = ""; inblock = 0; inmulti = 0; disabled = 0
    }
    function finish() {
      if (!disabled) report("file", "-", lines, 1)
    }
    {
      lines = FNR
      raw = $0
      if (raw ~ /swiftlint:disable(:next|:this)? .*file_length/) disabled = 1

      # Strip comments and string contents, tracking the multi-line states.
      code = ""
      s = raw
      while (length(s) > 0) {
        if (inblock) {
          i = index(s, "*/")
          if (i == 0) { s = ""; break }
          s = substr(s, i + 2); inblock = 0; continue
        }
        if (inmulti) {
          i = index(s, "\"\"\"")
          if (i == 0) { s = ""; break }
          s = substr(s, i + 3); inmulti = 0; code = code "\"\""; continue
        }
        c = substr(s, 1, 1); two = substr(s, 1, 2); three = substr(s, 1, 3)
        if (two == "//") break
        if (two == "/*") { inblock = 1; s = substr(s, 3); continue }
        if (three == "\"\"\"") { inmulti = 1; s = substr(s, 4); continue }
        if (c == "\"") {
          # Skip a one-line string, honouring backslash escapes.
          j = 2
          while (j <= length(s)) {
            d = substr(s, j, 1)
            if (d == "\\") { j += 2; continue }
            if (d == "\"") break
            j++
          }
          code = code "\"\""; s = substr(s, j + 1); continue
        }
        code = code c; s = substr(s, 2)
      }

      iscode = (code ~ /[^[:space:]]/)
      # A body line counts for every type opened on an earlier line.
      if (iscode) for (k = 1; k <= sp; k++) if (open_line[k] < FNR) cnt[k]++

      # A type declaration: the keyword, then a name that is not a member
      # (`class func`, `class var` are members, not types).
      if (code ~ /(^|[^A-Za-z0-9_.])(class|struct|enum|actor)[[:space:]]+[A-Za-z_]/) {
        t = code
        sub(/.*(^|[^A-Za-z0-9_.])(class|struct|enum|actor)[[:space:]]+/, "", t)
        match(t, /^[A-Za-z_][A-Za-z0-9_]*/)
        nm = substr(t, RSTART, RLENGTH)
        if (nm !~ /^(func|var|let|subscript|override|final|private|public|internal|fileprivate|open|static|case)$/) {
          pending = nm; pending_line = FNR
        }
      }

      n = length(code)
      for (p = 1; p <= n; p++) {
        ch = substr(code, p, 1)
        if (ch == "{") {
          depth++
          if (pending != "") {
            sp++; name[sp] = pending; open_depth[sp] = depth
            open_line[sp] = FNR; decl_line[sp] = pending_line; cnt[sp] = 0
            pending = ""
          }
        } else if (ch == "}") {
          if (sp > 0 && open_depth[sp] == depth) {
            # The closing line is not body: take back its count.
            if (iscode && open_line[sp] < FNR) cnt[sp]--
            report("type", name[sp], cnt[sp], decl_line[sp])
            sp--
          }
          depth--
        }
      }
    }
    END { if (NR > 0) finish() }
  ' "$@"
}

# Applies the limits to measure's output; returns 1 if anything is over.
judge() {
  local over=0
  local file kind name count line
  while IFS=$'\t' read -r file kind name count line; do
    local rel="${file#"$REPO_ROOT"/}"
    if [ "$kind" = "file" ]; then
      if [ "$count" -gt "$FILE_LIMIT" ]; then
        echo "error: $rel is $count lines, over SwiftLint's file_length limit of $FILE_LIMIT" >&2
        over=1
      elif [ "$count" -gt $((FILE_LIMIT - HEADROOM)) ]; then
        echo "note: $rel is $count/$FILE_LIMIT lines — a parallel PR growing it can tip the merge over"
      fi
    else
      # A type carrying its own disable is SwiftLint's business, not ours.
      if grep -qE "swiftlint:disable.*type_body_length" "$file"; then continue; fi
      if [ "$count" -gt "$TYPE_LIMIT" ]; then
        echo "error: $rel:$line type $name has ~$count body lines, over SwiftLint's type_body_length limit of $TYPE_LIMIT" >&2
        over=1
      elif [ "$count" -gt $((TYPE_LIMIT - HEADROOM)) ]; then
        echo "note: $rel:$line type $name has ~$count/$TYPE_LIMIT body lines"
      fi
    fi
  done
  if [ "$over" -ne 0 ]; then
    echo "       Split by topic the way the suites already do (Foo+Topic.swift, or a same-file" >&2
    echo "       extension for a type body) — trimming comments to squeeze under only moves" >&2
    echo "       the failure to the next PR that touches the file." >&2
  fi
  return "$over"
}

self_test() {
  local dir failed=0
  dir="$(mktemp -d "${TMPDIR:-/tmp}/swift-size.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: $dir is local
  trap "rm -rf '$dir'" RETURN

  # A struct whose braces in strings and comments must not count, with a nested
  # type, a `class func` member, and blank and comment-only lines in the body.
  cat >"$dir/Sample.swift" <<'SWIFT'
import Foundation

struct Outer {
  let a = "{ not a brace"

  // a comment { also not a brace
  /* block
     comment } */
  class func make() -> Outer { Outer() }
  enum Inner {
    case one
  }
  let b = """
    { multi-line }
    """
}

extension Outer {
  func ignored() {}
}
SWIFT
  local got
  got="$(measure "$dir/Sample.swift" | cut -f2-4 | tr '\t' ' ')"
  local want
  want="$(printf '%s\n' "type Inner 1" "type Outer 7" "file - 20")"
  if [ "$got" = "$want" ]; then
    echo "  ok   counts types and file length, ignoring strings and comments"
  else
    echo "  FAIL measured:" >&2
    printf '%s\n' "$got" | sed 's/^/         /' >&2
    echo "       expected:" >&2
    printf '%s\n' "$want" | sed 's/^/         /' >&2
    failed=1
  fi

  # The limits fire, and a file-level disable is honoured.
  awk 'BEGIN { for (i = 0; i < 401; i++) print "let x = 1" }' >"$dir/Long.swift"
  if judge < <(measure "$dir/Long.swift") >/dev/null 2>&1; then
    echo "  FAIL a 401-line file passed" >&2
    failed=1
  else
    echo "  ok   a 401-line file fails"
  fi
  {
    echo "// swiftlint:disable file_length"
    cat "$dir/Long.swift"
  } >"$dir/Disabled.swift"
  if judge < <(measure "$dir/Disabled.swift") >/dev/null 2>&1; then
    echo "  ok   swiftlint:disable file_length is honoured"
  else
    echo "  FAIL a disabled file still failed" >&2
    failed=1
  fi

  # The included list still matches .swiftlint.yml.
  local cfg
  cfg="$(sed -n '/^included:/,/^[a-z_]*:/p' "$REPO_ROOT/.swiftlint.yml" | sed -n 's/^  - //p' | tr '\n' ' ')"
  if [ "$cfg" = "${INCLUDED[*]} " ]; then
    echo "  ok   included paths match .swiftlint.yml"
  else
    echo "  FAIL .swiftlint.yml includes '$cfg', this script '${INCLUDED[*]}'" >&2
    failed=1
  fi
  return "$failed"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

cd "$REPO_ROOT"
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files -- "${INCLUDED[@]/%//*.swift}")
fi
[ "${#files[@]}" -gt 0 ] || exit 0

if judge < <(measure "${files[@]}"); then
  [ "$#" -gt 0 ] || echo "swift size budgets hold (file_length $FILE_LIMIT, type_body_length ~$TYPE_LIMIT)"
else
  exit 1
fi
