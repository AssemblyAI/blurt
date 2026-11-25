---
name: warn-zsh-unsplit-vars
enabled: true
event: bash
pattern: for\s+\w+\s+in\s+"?\$\{?[A-Za-z_]\w*\}?"?\s*;|git\s+(checkout|add|rm|restore)\b[^;&|\n]*\s\$\{?[A-Za-z_]\w*\}?(?=\s|;|$)
action: warn
---

⚠️ **A variable used as a list: zsh doesn't word-split it**

This shell is **zsh**. An unquoted `$VAR` is **not** split on spaces or newlines, so
`for x in $VAR` runs once over the whole string, and `git checkout --ours -- $U` gets
one argument naming a file that doesn't exist.

That happened twice in one session:

- `git checkout --ours -- $U` failed, and the `git add -A` after it **committed conflict markers**.
- a cleanup loop `for d in $T` treated every path as one, and **deleted nothing**.

Use one of these instead:

- an array: `T=(a b c); for d in "${T[@]}"; do …`
- explicit splitting: `${=VAR}` (zsh) or `$(echo $VAR)` in a pipeline
- a NUL-safe pipe: `git diff --name-only -z … | xargs -0 git checkout --ours --`

If `$VAR` holds exactly one value, this is fine; carry on.
