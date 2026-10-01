#!/bin/bash
# Assemble one use_figma call for the Blurt Keyboard Figma build: the tokens,
# core.js, the builder's module and the line that runs it, in one file under
# the tool's 50,000-character cap (App/BlurtiOS/Design/figma/README.md).
#
#   scripts/design-figma-call.sh foundations|components|layouts|theme-sheet|export-tokens|export-bounds|measure-apple
#
# Writes .build/figma-call/<builder>.js and prints its size. Only foundations
# carries tokens.js; every other builder reads the values back from the file's
# variables, so its call is just core.js and its module.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
BUILDER="${1:?usage: design-figma-call.sh <builder>}"
case "$BUILDER" in
  foundations) MODULE=foundations FN=buildFoundations ;;
  components) MODULE=components FN=buildComponents ;;
  layouts) MODULE=layouts FN=buildLayouts ;;
  theme-sheet) MODULE=themes FN=themeSheet ;;
  measure-apple) MODULE=themes FN=measureApple ;;
  export-tokens) MODULE=exports FN=exportTokens ;;
  export-bounds) MODULE=exports FN=exportBounds ;;
  *)
    echo "unknown builder $BUILDER" >&2
    exit 2
    ;;
esac
OUT="$REPO_ROOT/.build/figma-call"
mkdir -p "$OUT"
node - "$BUILDER" "$MODULE" "$FN" "$OUT" <<'JS'
const fs = require("fs");
const [builder, module, fn, out] = process.argv.slice(2);
const dir = "App/BlurtiOS/Design/figma/";
// Only foundations carries the data; every other builder reads it back from
// the file's variables and Gradient/* paint styles (core.js › ensureTokens).
const tokens = builder === "foundations" ? fs.readFileSync(dir + "tokens.js", "utf8") : "";
const strip = (text) => text.replace(/^\/\* global [^*]*\*\/\n/m, "");
const code =
  tokens +
  strip(fs.readFileSync(dir + "core.js", "utf8")) +
  strip(fs.readFileSync(dir + module + ".js", "utf8")) +
  `\nreturn await ${fn}();\n`;
const path = `${out}/${builder}.js`;
fs.writeFileSync(path, code);
const limit = 50000;
console.log(`${path}: ${code.length} chars${code.length > limit ? ` — OVER the ${limit} cap` : ""}`);
if (code.length > limit) process.exit(1);
JS
