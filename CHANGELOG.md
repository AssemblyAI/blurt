<!--
Release notes for Blurt's "What's new" sheet. This file is the source: the app
bundles it at build time and shows the new version's entry on the first launch
after an update (Help > What's New in Blurt shows it again). Parsed by
`Changelog` in the engine; `ChangelogTests` fails the build on an entry it can't
read.

Add an entry before bumping the version, newest at the top, shaped like the
0.1.57 one below:

- A `## <version> — <YYYY-MM-DD>` heading.
- Up to 3 headline features, each a `### <title>` heading followed by one
  paragraph saying what it does for the user. Any more are not shown; the rest
  belongs under Fixes.
- Optionally, under a feature's heading, a comment line naming its SF Symbol
  (`symbol: text.bubble`, written as an HTML comment like the ones below).
  Without one the feature gets `sparkles`.
- Optionally, a `### Fixes` heading with one `- ` bullet per fix.

Comments like this one are skipped.
-->
<!-- markdownlint-configure-file { "MD024": { "siblings_only": true } } -->

# Changelog

## 0.1.57 — 2026-09-29

### Text shortcuts

<!-- symbol: text.bubble -->

Say "work email" and Blurt types the whole address. Save the phrases you repeat, like a calendar link or a sign-off, in Settings.

### fn to dictate

<!-- symbol: keyboard -->

If fn is easier to reach on your keyboard, make it your trigger key.

### A calmer main window

<!-- symbol: macwindow -->

We rebuilt the main window and every Settings screen. Same controls, less on screen.

### Fixes

- Blurt now runs natively on Intel Macs, too.
- Dictation now pastes into Codex and other apps built on Electron.
- Better spacing in Google Docs after you click or type between dictations.
- Report a bug right from the main window footer.
