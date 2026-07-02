# Security Policy

Thanks for helping keep Blurt and its users safe.

## Reporting a vulnerability

Please report security issues **privately** — don't open a public issue, PR, or
discussion for anything exploitable.

Use GitHub's private reporting: go to the
[Security tab](https://github.com/AssemblyAI/blurt/security) and click
**Report a vulnerability**. That opens a private advisory visible only to the
maintainer and you.

Please include:

- what the issue is and where it lives (file, function, or feature),
- how to reproduce it, and
- the impact you think it has.

You'll get an acknowledgement, and we'll work with you on a fix and disclosure
timeline. This is a nights-and-weekends project, so responses are best-effort
rather than on a guaranteed clock — thanks for your patience.

## Scope

Blurt captures audio only during an active dictation session, sends it to
[AssemblyAI](https://www.assemblyai.com) to transcribe, and stores your API key
in the macOS Keychain. Issues in
AssemblyAI's service belong to
[AssemblyAI](https://www.assemblyai.com/docs); report those to them. Issues in
how Blurt handles audio, the API key, the clipboard, or the accessibility
permissions it uses are in scope here.

Blurt sends no telemetry — no crash reporting, no analytics, and no usage
tracking. The only network traffic the app produces is the dictation audio it
sends to AssemblyAI and the GitHub Releases check for self-updates.

## Supported versions

Blurt ships as a rolling release — fixes land in the latest
[release](https://github.com/AssemblyAI/blurt/releases/latest). Please make sure
you're on the newest build before reporting.
