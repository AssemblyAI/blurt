# AssemblyAI

The AssemblyAI API client that Blurt's engine is built on, kept free of Blurt policy so it can become
a standalone Swift SDK. Foundation only; macOS 15 and iOS 18.

| Type                                   | What it is                                                                           |
| -------------------------------------- | ------------------------------------------------------------------------------------ |
| `HTTPTransport`                        | The network seam. `URLSession` conforms, including a streamed (chunked) upload body. |
| `DictationConfig`, `DictationResponse` | The dictation API's `config` part and response, with only documented keys.           |
| `ErrorResponse`                        | The dictation API's two documented error shapes.                                     |
| `DictationMultipart`                   | The upload's multipart framing: `config` first, then the PCM audio.                  |
| `APIKeyValidator`                      | A cheap authenticated check that tells a rejected key from one it couldn't verify.   |

What it deliberately doesn't hold: which prompt, cleanup instruction or key terms to send, where the
key is stored, or the `User-Agent`. Those are the app's choices and live in `BlurtEngine`
(`AssemblyAITranscriber`, `APIKeyValidator.blurt()`).

Tests run with the engine's: `swift test` from the repo root.
