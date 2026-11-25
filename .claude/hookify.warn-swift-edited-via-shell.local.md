---
name: warn-swift-edited-via-shell
enabled: true
event: bash
pattern: (?s)sed\s+-i\b.*\.swift\b|\.swift\b.*write_text\(|write_text\(.*\.swift\b|>\s*[\w./+-]+\.swift\b
action: warn
---

⚠️ **Editing Swift through the shell skips the format and lint hooks**

The `swift-format.sh` and `swiftlint.sh` PostToolUse hooks only fire on the **Edit**
and **Write** tools. A `sed -i`, a python `write_text`, or a `>` redirect into a
`.swift` file is never formatted or linted. CI then runs `swift-format lint --strict`
and `swiftlint --strict`, where a long line or a missed wrap fails the build.

After this command, on every `.swift` file it touched, run:

```
swift-format format -i <files> && swift-format lint --strict <files> && swiftlint lint --quiet --strict <files>
```

Better still, make small Swift edits with the Edit tool, so the hooks run for you.
