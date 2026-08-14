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
# Every rule is also pinned to the prose it enforces, in both AGENTS.md's table
# and the guardrails skill: `--self-test` fails if either row goes missing. The
# rows move — PR #132 rewrote the `config.prompt` and language entries — and a
# rule outliving its row is the one failure this file cannot survive. It would
# still fire, still cite AGENTS.md, and still sound authoritative while enforcing
# a decision the project had reversed, which is strictly worse than the prose it
# replaced: prose that no longer reflects the design gets read and ignored, a
# gate that no longer reflects the design blocks the change that reflects it.
# Pinning both files also makes CLAUDE.md's "keep the two in agreement" — until
# now enforced by nobody — cost one grep.
#
# Adding a rule: put the pattern, the scope, the advice, a known-bad probe, and
# the two anchors at the SAME index in the six arrays. The self-test and the
# length assertion below are what keep a half-added rule from looking like a
# clean tree.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# The prose each rule answers to. Anchors are matched against these.
GUIDE="AGENTS.md"
GUARDRAILS=".claude/skills/project-guardrails/SKILL.md"

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
#
# Scopes name file *types*, not just directories, because these rules are about
# code and a directory holds more than code. `Sources` was all Swift until
# PR #137 moved BLURTENGINE.md to Sources/BlurtEngine/README.md — a document
# whose job is to explain these very decisions ("Do not replace this with a
# long-lived AVAudioEngine/installTap graph"). Prose about a rule is not a
# violation of it, and the whole-line-comment filter below can't help: a
# Markdown paragraph isn't a comment in any language grep knows. Restricting to
# code extensions also keeps the app scope off the .png and .m4a resources it
# was otherwise grepping byte by byte.
ENGINE="Sources/*.swift"
APP="App/Blurt/*.swift App/Blurt/*.yml App/Blurt/*.plist :!App/Blurt/Blurt.xcodeproj"
TESTS="Tests/*.swift App/Blurt/BlurtUITests/*.swift"

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
  "the trigger is home-grown (CGEventTap + DictationKeyGate); the package ban stands, chords are allowed"
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

# A verbatim slice of the row in AGENTS.md's "Settled decisions" table that each
# rule mechanizes — its "Don't" cell, which is the one part of a row phrased to
# be quoted. Matched with grep -F inside the table section only, so the pin is
# "the row is still there", not the weaker "these words appear somewhere in the
# guide". Rows are single lines (markdown tables cannot wrap), so a full cell is
# safe to use as an anchor.
TABLE_ANCHORS=(
  "Use \`AVAudioEngine\` / \`installTap\` for capture"
  "Add streaming STT"
  "Add a client-side LLM cleanup pass"
  "Add local models or model downloads"
  "Pin transcription to English, or set a language at all"
  "Bring back \`config.prompt\`"
  "Add a keystroke-typing paste path or a length threshold"
  "Add \`LSUIElement\` or a menu-bar-**only** mode"
  "Add a \`KeyboardShortcuts\` package (or any key-binding dependency)"
  "Add a self-replacing install or background auto-updater"
  "Touch the real Keychain in tests"
  "Add backwards-compat shims for removed types"
)

# The same rule as the guardrails skill words it. Deliberately not the table's
# wording: the skill is prose the agent reads, so it says the same things
# differently, and a pin that assumed identical text would only be checking that
# someone had copy-pasted. These are shorter than the table anchors because the
# skill's lines wrap and grep works a line at a time.
SKILL_ANCHORS=(
  "No \`AVAudioEngine\` / \`installTap\` capture path."
  "No streaming STT."
  "No separate LLM cleanup pass."
  "No local models / model downloads."
  "Don't set a language — not a directive, and not \`config.language_code\`."
  "There is no \`config.prompt\`."
  "Injection is always a clipboard paste"
  "no \`LSUIElement\`, no menu-bar-_only_ mode"
  "No \`KeyboardShortcuts\` package"
  "Updates are download-only"
  "the real Keychain in tests"
  "Don't add backwards-compat shims for removed types."
)

if [ "${#SCOPES[@]}" -ne "${#PATTERNS[@]}" ] \
  || [ "${#ADVICE[@]}" -ne "${#PATTERNS[@]}" ] \
  || [ "${#PROBES[@]}" -ne "${#PATTERNS[@]}" ] \
  || [ "${#TABLE_ANCHORS[@]}" -ne "${#PATTERNS[@]}" ] \
  || [ "${#SKILL_ANCHORS[@]}" -ne "${#PATTERNS[@]}" ]; then
  echo "error: the rule arrays are not the same length — a rule is half-added" >&2
  echo "       patterns=${#PATTERNS[@]} scopes=${#SCOPES[@]} advice=${#ADVICE[@]}" >&2
  echo "       probes=${#PROBES[@]} table_anchors=${#TABLE_ANCHORS[@]} skill_anchors=${#SKILL_ANCHORS[@]}" >&2
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

  # Every rule still answers to a documented decision. Scoped to the table
  # section rather than the whole guide, so a row that was deleted can't keep
  # its pin alive by being mentioned in passing somewhere else in AGENTS.md.
  TABLE="$(sed -n '/^## Settled decisions/,/^Release-side invariants/p' "$GUIDE")"
  # The extraction failing would report every rule as unpinned at once, which
  # reads like a catastrophe and is really a renamed heading. Say so instead.
  if [ -z "$TABLE" ]; then
    echo "  FAIL could not find the 'Settled decisions' table in $GUIDE" >&2
    echo "       (the heading or the closing 'Release-side invariants' paragraph moved;" >&2
    echo "       fix the extraction here rather than the anchors below)" >&2
    exit 1
  fi

  for i in "${!PATTERNS[@]}"; do
    if printf '%s\n' "$TABLE" | grep -qF -- "${TABLE_ANCHORS[$i]}"; then
      echo "  ok   rule $i is pinned to its $GUIDE row"
    else
      echo "  FAIL rule $i has no row in $GUIDE's settled-decisions table:" >&2
      echo "       ${TABLE_ANCHORS[$i]}" >&2
      failed=1
    fi
    if grep -qF -- "${SKILL_ANCHORS[$i]}" "$GUARDRAILS"; then
      echo "  ok   rule $i is pinned to $GUARDRAILS"
    else
      echo "  FAIL rule $i has no entry in $GUARDRAILS:" >&2
      echo "       ${SKILL_ANCHORS[$i]}" >&2
      failed=1
    fi
  done

  if [ "$failed" -ne 0 ]; then
    echo "" >&2
    echo "       A rule whose prose is gone is the one failure this gate can't survive:" >&2
    echo "       it would keep firing, keep citing AGENTS.md, and keep sounding right" >&2
    echo "       while enforcing something the project had already reversed. So decide," >&2
    echo "       don't patch: if the row was only reworded, update the anchor; if the" >&2
    echo "       decision was reversed, delete the rule with it." >&2
    exit 1
  fi
  echo "check-invariants.sh: all ${#PATTERNS[@]} rules live and pinned to their prose"
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
