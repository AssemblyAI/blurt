# AssemblyAI

The AssemblyAI API client that Blurt's engine is built on, kept free of Blurt policy so it can become
a standalone Swift SDK. Foundation (plus CryptoKit for the PKCE challenge); macOS 15 and iOS 18.

| Type                                   | What it is                                                                            |
| -------------------------------------- | ------------------------------------------------------------------------------------- |
| `HTTPTransport`                        | The network seam. `URLSession` conforms, including a streamed (chunked) upload body.  |
| `DictationConfig`, `DictationResponse` | The dictation API's `config` part and response, with only documented keys.            |
| `ErrorResponse`                        | The dictation API's two documented error shapes.                                      |
| `DictationMultipart`                   | The upload's multipart framing: `config` first, then the PCM audio.                   |
| `APIKeyValidator`                      | A cheap authenticated check that tells a rejected key from one it couldn't verify.    |
| `KeyTerms`                             | Key terms for `keyterms_prompt`: parse a comma-separated list, fit it to the caps.    |
| `OAuthAuthorization`                   | One "Sign in with AssemblyAI" attempt: PKCE verifier, `state`, consent URL, callback. |
| `OAuthClient`                          | Token endpoint (code, refresh) and the API-key exchange and revoke routes.            |

What it deliberately doesn't hold: which prompt, cleanup instruction or key terms to send, where the
key or the key terms are stored, the `User-Agent`, or anything done to the text on the device (text
shortcuts, `TextShortcutExpander`). Those are the app's choices and live in `BlurtEngine`
(`AssemblyAITranscriber`, `KeyTermsStore`, `TextShortcuts.swift`, `APIKeyValidator.blurt()`).

Tests run with the engine's: `swift test` from the repo root.
