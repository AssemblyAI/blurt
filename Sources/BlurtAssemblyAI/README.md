# BlurtAssemblyAI

The provider package that runs `BlurtEngine` on AssemblyAI. The engine names no speech provider: it
asks for transcription, a voice, an LLM and a key check through its provider seams (see the engine's
[README](../BlurtEngine/README.md#the-provider-seams)). This package conforms the standalone
[`AssemblyAI`](../AssemblyAI/README.md) SDK to those seams and applies Blurt's choices on the way.

| Type                                                | What it is                                                                                                                                                                                                                                                  |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AssemblyAITranscriber`                             | `TranscriberProtocol` over `DictationClient`: the `config` Blurt sends (`STTPrompt`, `KeyTerms.fitted`, `CleanupInstruction`, rewrite mode) and which transcript gets pasted, turning away a rewrite that only echoes its instruction (`RewriteGrounding`). |
| `KeyRejectionReporter`                              | Wraps a transcriber to report a dictation refused for its key, so a signed-in account renews at once.                                                                                                                                                       |
| `SpeechServices.assemblyAI()`                       | Read-aloud's voice (`AssemblyAISpeechSynthesizer`, over `SpeechClient`) and every LLM client's connection (`GatewayConnection.assemblyAI()`, over `GatewayChatClient`, each `ChatModelTier` on its gateway model), with the stored key.                     |
| `GatewayClient.init(apiKeyProvider:transport:)`     | Any of the engine's LLM clients (`TranscriptLLM`, `SelectionRewriter`, …) on the LLM Gateway.                                                                                                                                                               |
| `FileTranscriber`                                   | A recording's transcript through the async API, speaker-labelled.                                                                                                                                                                                           |
| `RealtimeTranscriber.blurt(apiKey:)`                | A realtime session with Blurt's User-Agent, and `LiveTranscript.apply(_:)` for its turns.                                                                                                                                                                   |
| `APIKeyValidator.blurt()`, `APIKeyModel(keyStore:)` | The key check, with Blurt's User-Agent, as the engine's `KeyValidation`.                                                                                                                                                                                    |
| `AssemblyAIAccount` and `Account/`                  | Sign in with AssemblyAI: the OAuth flow, the stored session, its renewal, and the data-zone dictation host (`DictationOrigin`).                                                                                                                             |

Every request carries Blurt's `User-Agent` (`UserAgent.current`) and reads the key from the engine's
`APIKeyStore` unless told otherwise.

**Another provider.** A Deepgram package, say, would sit beside this one: import `BlurtEngine` and its
own SDK, conform to the seams it serves (a `TranscriberProtocol`, a `SpeechSynthesizing`), and let a
host mix them — Deepgram's transcriber in `DictationSession`, this package's `SpeechServices` for
read-aloud and the LLM keys. Nothing in the engine changes.

Tests run with the engine's: `swift test` from the repo root.
