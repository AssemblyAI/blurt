#!/bin/bash
# The mechanical half of AGENTS.md's "Settled decisions — don't reintroduce these".
#
# Every entry in that table was tried the other way and reverted, and until now
# each one was enforced only by a reader remembering it: the table is prose, and
# `.claude/skills/project-guardrails` is the same prose compressed. That is
# enforcement exactly as long as attention holds — and the failure mode is a
# reviewer nodding through the one line that re-adds `AVAudioEngine` capture or
# an `LSUIElement` key.
#
# This file carries the subset of that table a regex can decide. It is not the
# whole table and cannot be: some entries are structural (the SPM-dependency
# guard parses project.yml's `packages:` block, so it stays in check.sh), some
# are already mechanized elsewhere (the pbxproj drift check, the PreToolUse
# hook), and some are genuinely undecidable from a grep — the "no filler-word
# clause" rule is about the *transcription prompt*, while `CleanupInstruction`'s
# rewrite instruction legitimately names filler sounds, and no pattern separates
# those two without also flagging the correct one. A rule that fires on correct
# code gets routed around, so those stay prose and stay in review.
#
# Shape is deliberately `check-portability.sh`'s: parallel pattern/advice arrays,
# a per-rule probe asserted by `--self-test`, and an escape hatch. The two gates
# answer the same kind of question — "does this tree contain a construct we
# decided against?" — so they should be read and extended the same way.
#
# Escape hatch: end the line with `// invariant-ok: <reason>` (or `# invariant-ok:`
# in yml/plist) when a flagged line is genuinely intended. Whole-line comments are
# skipped, so prose *about* a settled decision — which the sources carry a lot of,
# since each one documents why it is what it is — doesn't trip the gate.
#
# Adding a rule: put the pattern, the advice, the scope, and a known-bad probe at
# the SAME index in the four arrays. The self-test and the length assertion below
# are what keep a half-added rule from looking like a clean tree.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Scopes are git pathspecs, word-split at use. They are load-bearing, not
# decoration: most of these terms appear legitimately somewhere in the repo, and
# the scope is what separates "the engine sends this field" from "a test asserts
# it is absent". `language_code` is the clearest case — `KeytermsWireTests`
# contains `#expect(object.keys.contains("language_code") == false)`, which is
# the invariant being *enforced*, so the rule looks at Sources/ only.
#
# The generated Xcode project is excluded everywhere: it is derived from
# project.yml (check.sh fails on drift), so scanning it would report every
# finding twice and invite a fix in the file that gets overwritten.
ENGINE="Sources"
APP="App/Blurt :!App/Blurt/Blurt.xcodeproj"
TESTS="Tests App/Blurt/BlurtUITests"

# Four parallel arrays rather than one delimited list, for the reason
# check-portability.sh gives: the patterns contain `|`, so splitting on it
# truncates a pattern mid-expression, and a truncated regex is a rule that
# silently never matches.
PATTERNS=(
  "AVAudioEngine|installTap"
  "URLSessionWebSocketTask|wss://"
  "StylerProtocol|LLMGateway|LemurClient|/lemur/"
  "import Speech|import CoreML|SFSpeechRecognizer|MLModel"
  "\"language_codes?\""
  "\"prompt\""
  "SetUnicodeString"
  "LSUIElement"
  "import KeyboardShortcuts"
  "AppUpdater|Sparkle|SPUUpdater"
  "KeychainStore\\(service: *(BlurtIdentity\\.keychainService|\"blurt\")"
  "@available\\(\\*, *deprecated"
)
SCOPES=(
  "$ENGINE $APP"
  "$ENGINE $APP"
  "$ENGINE $APP"
  "$ENGINE $APP"
  "$ENGINE"
  "$ENGINE"
  "$ENGINE $APP"
  "$APP"
  "$ENGINE $APP"
  "$ENGINE $APP"
  "$TESTS"
  "$ENGINE $APP"
)
ADVICE=(
  "MicCapture uses a fresh AVAudioRecorder per session — a long-lived engine goes stale on a device switch"
  "the dictation API returns the full text in one response; there is no streaming path"
  "cleanup is the API's server-side rewrite via the llm block on the same /transcribe call"
  "transcription is a remote AssemblyAI call — no on-device ASR/LLM, no model cache"
  "leave language to the model's own detection; setting the field takes that away"
  "config.prompt was replaced by config.conversation_context (ConversationContext)"
  "injection is always clipboard paste (save → write → ⌘V → settle → restore)"
  "Blurt is a Dock app first; the MenuBarExtra item is layered on, never depended on"
  "the trigger is a home-grown lone modifier (CGEventTap + DictationKeyGate)"
  "updates are download-only; extend UpdateCheckModel, don't install for the user"
  "use an isolated service (see KeychainStoreTests) or InMemoryAPIKeyStore"
  "deleted types stay deleted — no deprecated re-exports"
)

# One known-bad line per rule, same order. `--self-test` asserts each pattern
# matches its own probe: a rule that matches nothing is indistinguishable from a
# clean tree, and this table's whole job is to be right about a tree that has
# been clean since the day each decision was made.
PROBES=(
  "let engine = AVAudioEngine()"
  "let task = session.webSocketTask(with: url) as URLSessionWebSocketTask"
  "protocol StylerProtocol { func style(_ text: String) async throws -> String }"
  "import CoreML"
  "case languageCode = \"language_code\""
  "case prompt = \"prompt\""
  "CGEventKeyboardSetUnicodeString(event, count, chars)"
  "    LSUIElement: true"
  "import KeyboardShortcuts"
  "let updater = AppUpdater(owner: \"assemblyai\", repo: \"blurt\")"
  "let store = KeychainStore(service: BlurtIdentity.keychainService, account: \"AssemblyAIAPIKey\")"
  "@available(*, deprecated, renamed: \"NewName\")"
)

if [ "${#SCOPES[@]}" -ne "${#PATTERNS[@]}" ] \
  || [ "${#ADVICE[@]}" -ne "${#PATTERNS[@]}" ] \
  || [ "${#PROBES[@]}" -ne "${#PATTERNS[@]}" ]; then
  echo "error: the rule arrays are not the same length — a rule is half-added" >&2
  echo "       patterns=${#PATTERNS[@]} scopes=${#SCOPES[@]} advice=${#ADVICE[@]} probes=${#PROBES[@]}" >&2
  exit 1
fi

if [ "${1:-}" = "--self-test" ]; then
  failed=0
  for i in "${!PATTERNS[@]}"; do
    if printf '%s\n' "${PROBES[$i]}" | grep -qE "${PATTERNS[$i]}"; then
      echo "  ok   rule $i flags: ${PROBES[$i]}"
    else
      echo "  FAIL rule $i does not match its own probe: ${PROBES[$i]}" >&2
      failed=1
    fi
  done

  # The negatives matter as much: a gate that flags the correct form is a gate
  # people route around. Each of these is a real line from this tree that sits
  # one character away from a rule above — the Accessibility prompt dictionary
  # against the `"prompt"` wire key, the test keychain against the production
  # one, the download-only checker against a self-replacing updater.
  GOOD=(
    "let prompt: NSDictionary = [\"AXTrustedCheckOptionPrompt\": true]"
    "KeychainStore(service: \"dev.alex.blurt.tests\", account: \"test-\\(UUID().uuidString)\")"
    "@MainActor public final class UpdateCheckModel: ObservableObject {"
    "case conversationContext = \"conversation_context\""
  )
  for good in "${GOOD[@]}"; do
    hit=""
    for i in "${!PATTERNS[@]}"; do
      if printf '%s\n' "$good" | grep -qE "${PATTERNS[$i]}"; then
        hit="$i"
        break
      fi
    done
    if [ -n "$hit" ]; then
      echo "  FAIL rule $hit flags a correct line: $good" >&2
      failed=1
    else
      echo "  ok   correct form allowed: $good"
    fi
  done

  [ "$failed" -eq 0 ] || exit 1
  echo "check-invariants.sh: all ${#PATTERNS[@]} rules live"
  exit 0
fi

# git ls-files sees tracked files only, so a brand-new source file is invisible
# here until it is staged — and a scan that skips the file you just wrote reads
# exactly like a scan that approved it. Warn rather than fail, because an
# untracked file is a normal state mid-edit; `git add -N` brings it into scope.
UNTRACKED=$(git ls-files --others --exclude-standard -- Sources Tests App/Blurt)
if [ -n "$UNTRACKED" ]; then
  echo "note: untracked files are NOT scanned (git add -N to include them):"
  printf '%s\n' "$UNTRACKED" | sed 's/^/  /'
fi

VIOLATION=0
for i in "${!PATTERNS[@]}"; do
  pattern=${PATTERNS[$i]}
  advice=${ADVICE[$i]}
  scope=${SCOPES[$i]}

  # A scope typo kills a rule exactly as quietly as a broken regex does — the
  # file list comes back empty, grep finds nothing, and the rule reports clean
  # forever. The self-test can't see this (it feeds probes on stdin, not files),
  # so the emptiness is checked here, where the real paths are.
  # shellcheck disable=SC2086
  files=$(git ls-files -- $scope)
  if [ -z "$files" ]; then
    echo "error: rule $i has a scope that matches no tracked files: $scope" >&2
    exit 1
  fi

  # grep exits 1 on "no match" (the good case) and 2+ on a bad pattern. Those
  # are distinguished on purpose: `|| true` over both would turn a broken regex
  # into a rule that passes everything.
  status=0
  # shellcheck disable=SC2086
  hits=$(grep -nE "$pattern" $files) || status=$?
  if [ "$status" -gt 1 ]; then
    echo "error: rule $i is not a valid regex (grep exit $status): $pattern" >&2
    exit 1
  fi
  [ -n "$hits" ] || continue

  # Drop whole-line comments and anything marked invariant-ok. Swift `//` and
  # `///`, block-comment continuations, and `#` for the yml/plist scope. The
  # filename:lineno: prefix is stripped for the test, not for the report.
  hits=$(printf '%s\n' "$hits" | awk '
    { body = $0; sub(/^[^:]*:[0-9]+:/, "", body) }
    body ~ /invariant-ok:/ { next }
    body ~ /^[[:space:]]*(#|\/\/|\*|\/\*)/ { next }
    { print }
  ')
  [ -n "$hits" ] || continue

  echo "error: settled decision reintroduced — ${advice}:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  VIOLATION=1
done

[ "$VIOLATION" -eq 0 ] || {
  echo "       Each of these was tried the other way and reverted; see the" >&2
  echo "       'Settled decisions' table in AGENTS.md for what happened. If a task" >&2
  echo "       really needs one, stop and ask — don't route around the gate. Mark a" >&2
  echo "       false positive with a trailing '// invariant-ok: <reason>' comment." >&2
  exit 1
}

echo "${#PATTERNS[@]} settled decisions hold"
