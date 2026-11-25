# AssemblyAI

A Swift SDK for AssemblyAI's APIs, with no Blurt code in it, so another speech project can use it on
its own. Foundation (plus CryptoKit for the PKCE challenge); macOS 15 and iOS 18. Blurt runs on it
through the `BlurtAssemblyAI` provider package (`Sources/BlurtAssemblyAI/`); `BlurtEngine` itself
imports neither.

```swift
// Package.swift
.target(name: "YourApp", dependencies: [.product(name: "AssemblyAI", package: "blurt")])
```

| Type                                   | What it is                                                                                                                                              |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `HTTPTransport`                        | The network seam. `URLSession` conforms, including a streamed (chunked) upload body.                                                                    |
| `DictationClient`                      | The dictation API: audio streamed up while it is recorded, one response back; the documented `/v1/transcribe` fallback past the live route's 120 s cap. |
| `DictationConfig`, `DictationResponse` | The dictation API's `config` part and response, with only documented keys.                                                                              |
| `ErrorResponse`, `AssemblyAIError`     | The dictation API's two documented error shapes, with `error_code` when present, and the client's errors.                                               |
| `KeyTerms`                             | Key terms for `keyterms_prompt`: fit a clean list to the field's two caps.                                                                              |
| `DictationLimits`                      | What a recording may be: the 16 kHz geometry, the 20-minute cap, and the ~80 ms floor below which nothing is transcribed.                               |
| `DictationPrompt`                      | `stt_prompt`: fit passages to the field's 4096-scalar cap, oldest dropped first.                                                                        |
| `SpeechClient`                         | The streaming TTS API: one `POST /v1/speech` per piece, its PCM read as it arrives.                                                                     |
| `SpeechSegmenter`                      | Cut text at sentence ends for `SpeechClient`, the voice's measured rule.                                                                                |
| `GatewayChatClient`                    | The LLM Gateway: one `POST /v1/chat/completions`, answered whole.                                                                                       |
| `APIKeyValidator`                      | A cheap authenticated check that tells a rejected key from one it couldn't verify.                                                                      |
| `OAuthAuthorization`                   | One "Sign in with AssemblyAI" attempt: PKCE verifier, `state`, consent URL, callback.                                                                   |
| `OAuthClient`                          | Token endpoint (code, refresh) and the API-key exchange and revoke routes.                                                                              |
| `AsyncTranscriptionClient`             | The async API: upload a file, submit it with speaker labels, poll until it's done.                                                                      |
| `RealtimeTranscriber`                  | The realtime streaming API over a WebSocket.                                                                                                            |

Every client takes the API key from its caller and an optional `userAgent` naming the calling app, and sends
only what AssemblyAI's API reference documents.

What it deliberately doesn't hold: which prompt, cleanup instruction, key terms, model or voice to
send, where the key or the key terms are stored, which of a dictation's two transcripts to use, or
anything done to the text on the device. Those are the calling app's choices; Blurt's live in
`BlurtAssemblyAI` (`AssemblyAITranscriber`, `SpeechServices.assemblyAI()`, `APIKeyValidator.blurt()`)
and the engine (`KeyTermsStore`, `TextShortcutExpander`).

Tests run with the engine's: `swift test` from the repo root.
