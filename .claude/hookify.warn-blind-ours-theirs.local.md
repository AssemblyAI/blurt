---
name: warn-blind-ours-theirs
enabled: true
event: bash
pattern: git\s+checkout\b[^\n]*\s--(ours|theirs)\b
action: warn
---

⚠️ **Taking one side of a conflict wholesale**

`git checkout --ours` / `--theirs` keeps one side of **every** hunk in those files. That
is only right if the other side's changes are all ones this branch already has (the
"squash effect": a PR merged into this branch, then squashed onto main). If **another**
PR changed the same file on main, keeping one side silently drops that PR's work. In
one session this nearly dropped #372's realtime lifecycle guards while resolving #363.

Before taking a side, check that the other side holds nothing new:

- compare the file as it landed with the version this branch merged:
  `a=$(git show <merged-ref>:"$f" | git hash-object --stdin); b=$(git show <landed-commit>:"$f" | git hash-object --stdin)`
- or list what else touched it: `git log --oneline <merge-base>..origin/main -- "$f"`

If they're identical, or the only other change is the one being merged, taking a side
is safe. Otherwise resolve hunk by hunk, then check that the other PR's changes are
still present.
