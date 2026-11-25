# ARCHITECTURE.md

How Blurt works, part by part: the engine's pipeline, the hotkey, the contextual prompt, settings and
cues, the app shell and updates. It is the reference half of [`AGENTS.md`](./AGENTS.md), moved out so
that guide stays short enough for every agent session to read in full; read the section here for the
code you are changing. Where the two disagree,
[`AGENTS.md`'s Settled decisions](./AGENTS.md#settled-decisions--dont-reintroduce-these) win.

## How the pipeline works

```text
DictationKeyTap (CGEventTap + DictationKeyGate) → AppCoordinator → DictationSession (actor) → MicCapture
                       ↓
              AssemblyAITranscriber  (STT + LLM cleanup, dictation API: one POST /v1/transcribe/live;
                                      past its 120 s cap, the whole recording to /v1/transcribe)
                       ↓
              KeyInjector → focused app (clipboard paste via a synthesized ⌘V CGEvent)
```

### `MicCapture` — `Sources/BlurtEngine/Audio/MicCapture.swift`

An actor implementing `MicCaptureProtocol`. It captures with an **`AVCaptureSession`** recorder
(`CaptureSessionRecorder`, used directly — the `CaptureRecorder` protocol that once abstracted two
backends went with the second one; the owner-directed move from `AVAudioRecorder`, 2026-08-25): the
session's audio data output converts to 16 kHz / mono / 16-bit
LPCM — the exact geometry the dictation API wants — and the delegate accumulates the raw S16LE
bytes onto the feed `start()` returns, which is what the chunked upload drains while the user is
still speaking — no temp file, no read-back, and no resampling or float-conversion pass. `stop()`
answers a **byte count**, not the audio: the recording has already gone out by then, so all the
release path needs is whether there was enough of it to send (`RecordingLimits.minPCMBytes`).
Accumulating the blob as well cost a second `memcpy` of every byte inside the capture lock and
retained a duplicate of the whole utterance until release. The one copy of the recording that does
exist now lives in the transcriber, not here: the upload layer keeps it, off the capture lock, to
back [the over-cap fallback](#the-over-cap-fallback) and nothing else.

A **fresh recorder per session**, built around the _current_ resolution of the user's selection at
press time; this is deliberate — see
[Settled decisions](./AGENTS.md#settled-decisions--dont-reintroduce-these) for the `AVAudioEngine` failure it
replaced.

**Microphone selection** is that resolution: a device pinned in Settings (`MicDeviceStore`,
persisted as the device UID — `AVCaptureDevice(uniqueID:)` takes the same string) or the system
default input. The transport-keyed policies (liveness cap, tail linger) key off the **pinned**
device, and a pinned device that isn't connected falls back to the system default per press
(`MicDeviceSelection.effective` — pure and unit-tested; the pin stays stored). Enumeration, naming
and presence live in `AudioInputDevices`, on `AVCaptureDevice` — the same API the recorder opens the
device with, so the picker can't offer something the capture path would then call missing. So does
the transport read, once `AVCaptureDevice.transportType` was confirmed on hardware to report the same
four-character codes CoreAudio does for every case the policies turn on — `blue` on AirPods most of
all, since a transport that fails to read as Bluetooth silently costs the 2.5 s liveness cap and the
220 ms tail linger. Hardware-bound and coverage-excluded.

**Bluetooth inputs are the reason for three of this actor's moving parts.** Opening the mic on
AirPods (or any Bluetooth headset) makes the system renegotiate the link into its mic-capable mode —
one to two seconds, during which the OS receives no audio at all — and that link then buffers audio
in both directions. So:

- **`start()` does not return until the input is live.** `record()` returning `true` only means the
  session started running, not that frames are arriving, so `start()` polls the recorder until **both**
  it has delivered at least one frame **and** its meter reads above `MicLiveness.silenceFloorDB`. The
  clock alone is not enough: macOS can deliver all-zero buffers from a stale or not-yet-switched
  device, and frames of digital silence arrive and count exactly like real audio — so the gate was
  satisfied on its first ~1 ms poll while the AirPods link was still renegotiating. The floor
  discriminates _digital_ silence from any real analog input (a live mic in a quiet room still reads
  its own self-noise, far above it); it is deliberately **not** a speech threshold, which would hang
  every press in a quiet room instead. Capped per transport by **`MicLiveness`** (2.5 s Bluetooth,
  300 ms on a recognised local transport, 1 s for anything else — an aggregate or virtual device can
  have AirPods switching underneath it) and **failing closed** on timeout: the recorder is torn down
  and `start()` throws `.audioCaptureFailed`, so the press ends in the same error pill as any other
  capture failure rather than recording an utterance the mic never heard. (The gate originally failed
  open, proceeding as if live — which cued the user to speak into a dead mic anyway.) Audio spoken
  during the switch cannot be recovered by anything, because nothing ever receives it. Where that cost lands differs by
  transport, measured: on a USB interface `startRunning()` blocks for ~600 ms and the first frame
  follows ~8 ms later, so the gate confirms almost at once; on AirPods `startRunning()` returns in
  ~80 ms and the first frame arrives ~410 ms after that, so the gate is doing the waiting. Both end
  in the same place because the wait's clock starts _after_ `record()` returns — a slow open eats
  none of the frame-arrival budget, which is what lets the caps be this tight.

  **The bring-up is off-actor.** Building the session and opening the device are both `async`, run
  on the recorder's serial `controlQueue`, so neither blocks the actor: the ~600 ms open, and the
  build before it (~5 ms warm, ~185 ms on a process's first touch of the capture stack). Only the
  selection lookup stays inline, at microseconds once warm. Run inline it did both: a teardown arriving during the open measured **578 ms** of
  waiting on a 635 ms open, against **24 µs** once suspended (`MicCaptureBringUpTests`, which warms
  the stack first so it measures this rather than a process's first touch, then asserts an absolute
  budget that holds on every input). It
  also parked a cooperative-pool thread for the duration — the same pool the overlapping context
  capture and the transcriber's connection warm-up run on, and starving it is how covering the
  retired backend in CI deadlocked the whole test run, which is why the hop is a `DispatchQueue`
  rather than a detached `Task`. Through `DictationSession` the win is latent rather than visible:
  its serial command queue already runs release and cancel only after the press turn completes, and
  `cancel()` claims `.cancelled` synchronously without touching the mic. But `MicCapture` is a
  public actor and the contract has to hold for a host that doesn't serialize its own commands.
  `stopRunning()` stays inline, at 19–41 ms against the open's ~600.

  The suspension is also why the teardown snapshot moved: `stopGeneration` is now read before the
  open rather than before the liveness wait, and checked at both ends, because a stop or cancel can
  land while the input is still coming up. `stopGeneration`
  covers the suspensions this introduces — a teardown landing anywhere in the bring-up wins, and the
  recorder is torn down rather than installed. The check is written at each suspension; the teardown
  itself is one `defer`, so a new suspension point inherits it.

  **A cancel preempts the bring-up rather than queueing behind it**, which took two pieces. The
  press publishes its task handle (`inFlightPress`) exactly as the pipeline publishes
  `pipelineTask`, and `cancel()` treats `.connecting` like the other in-flight phases: cancel the
  handle, claim `.cancelled`, return. `waitUntilLive` already honors task cancellation, so the wait
  unblocks at once and `start()` throws `CancellationError` rather than installing the recorder.
  The cancel flag then lives in a `Mutex` beside that handle rather than in actor state, so
  **`submit(.cancel)` can record and preempt without waiting for a turn** — the app's cancel door is
  `submit`, and its consumer is serial, so before this a submitted `.cancel` wasn't even _recorded_
  until the press it meant to cancel had finished. `requestCancel()` is the single place both doors
  funnel through. Commands are still yielded and executed in order; only the preemption is new.
  `performPress` still consumes the flag before claiming `.recording`, for the narrow window where
  the cancel lands after the wait returned and there is nothing left to interrupt.

- **There is no warm recorder** — the bring-up cost is not pre-payable, and that is a
  measurement, not a preference. Timed against CoreAudio's own
  `kAudioDevicePropertyDeviceIsRunningSomewhere` (the bit behind the input indicator): building an
  `AVCaptureSession` leaves the device closed and costs ~15 ms, while `record()`'s `startRunning()`
  opens it and costs 180 ms on the built-in mic and ~600 ms on a USB interface. The retired
  `AVAudioRecorder.prepareToRecord()` measured the same way — ~3 ms, device still closed, and a cold
  `record()` after it cost 614 ms versus 585 ms with no prepare at all. **Neither API ever pre-paid
  the route activation**, so the machinery that assumed one did (a recorder re-warmed after every
  capture, validated against the resolved device identity and pin, a 60 s expiry to un-pin AirPods
  from their degraded output profile, and a `bringingUpCapture` flag to stop a re-warm racing a live
  press) was buying ~15 ms of a ~600 ms bring-up. It was deleted in favour of a stateless
  `warmUp()`: build one session at launch and drop it, which absorbs the ~185 ms a process pays the
  _first_ time it touches AVFoundation's capture stack (~90–125 ms of that the first device query
  alone) and holds nothing afterwards. The live
  suite pins the load-bearing half — building, and warming, must leave the microphone closed.

`stop()` also waits out `AudioTransport.tailLinger(forTransportType:)` (220 ms on Bluetooth, `.zero`
otherwise — the policy sits beside `MicLiveness`'s wait cap so both are unit-tested) before ending
the recording **when the
session's input is Bluetooth**, so speech still travelling over the link lands in the recording
instead of being truncated — the missing last word. It runs after `.transcribing` is claimed, so it
delays the transcript, never the "it heard me" cue. Cancels take `cancelCapture()` instead, which
skips the linger: the audio is being discarded, so it isn't worth delaying the user's cancel for.

What a transport _means_ is **`AudioTransport.isBluetooth`** and **`MicLiveness.timeout`**, which
are pure and unit-tested; the reads that feed them are hardware-bound and coverage-excluded, so don't
let a decision drift into them. **`AudioRoute`** (`Audio/AudioRoute.swift`, internal) is what's left
of the CoreAudio side after the input reads moved to `AVCaptureDevice`: the default _output_ device,
plus the property addressing its sibling shares. Its sibling
**`AudioRouteMonitor`** (public) publishes output-route changes for the cue players — see
[Settings, persistence, and cues](#settings-persistence-and-cues). Both are excluded from the
coverage gate for the same reason
`MicCapture` is: they answer questions only real hardware can answer.

The overlay meter (`levels`) comes from the recorder's dBFS power on a ~20 Hz timer
(`MicCapture.meterIntervalSeconds` — public because the pill caps its animation redraws to the same
cadence and reads it from here rather than restating it), mapped to `0…1` by
`linearLevel(fromPowerDB:)` and floored so room ambient reads as empty bars rather than a meter that
never rests. `levels`, `warmUp()` and `cancelCapture()` are part of `MicCaptureProtocol` itself with
empty-stream / no-op / stop-and-discard defaults, so stubs conform with just `start()`/`stop()` while
hosts still read the meter through the seam they inject.

### `AssemblyAITranscriber` — `Sources/BlurtAssemblyAI/AssemblyAITranscriber.swift`

The engine names no provider: `DictationSession` transcribes through `TranscriberProtocol`, and the
host hands it a conformer. Blurt's is `AssemblyAITranscriber`, in the `BlurtAssemblyAI` provider
package, which builds each request's `config` (Blurt's policy: prompt, key terms, cleanup
instruction, rewrite mode) and picks the transcript to paste, and sends it through the SDK's
`DictationClient` (`Sources/AssemblyAI/Dictation/`), which owns the wire: the streamed body, the
over-cap fallback, the warm-up and the latency logging. Together they implement `TranscriberProtocol`
against AssemblyAI's **dictation** API: a single
`POST https://dictation.assemblyai.com/v1/transcribe/live` with a JSON `config` part
(`sample_rate`, `channels`, and the rewrite request) followed by the captured audio as a raw S16LE PCM
blob in the `audio` part. No model header — the service pins the STT model server-side. Every
request to AssemblyAI (this POST, its `/warm` GET, and `APIKeyValidator`'s key check) also carries
`User-Agent: Blurt/<CFBundleShortVersionString> (macOS <major>.<minor>)`, with `; dev` appended on
anything but a release build — so a server-side latency or error-rate change is attributable to the
release that caused it, and local `dev-build.sh` traffic doesn't pollute that baseline. `UserAgent`
holds the reasoning: why those three dimensions and not architecture, `CFBundleVersion`, locale or
anything per-install; why the header says strictly less than `URLSession`'s default did; and why a
header the reference doesn't list is not the undocumented-parameter rule being bent (every HTTP
client sends this one regardless; the choice is only what it says). The config's
`stt_prompt` field steers _transcription_ and carries the user's recent dictations followed
by the text before the cursor (`STTPrompt.text`), or nothing at all when there is neither —
an empty string omits the field. There is no `prompt` field — the route accepts one, so that
absence is the settled decision and not a constraint. `config.llm_instruction` asks the
service to run our LLM cleanup rewrite (remove disfluencies, fix punctuation) over the
verbatim transcript, all inside the same request, and it rides **every** request:
`DictationConfig` carries no rewrite on/off switch at all.

**The switch is applied to the response, not the request** (since 2026-09-11). The response
carries both `text` (the verbatim transcript, "never altered by the LLM") and `llm_response`
(the rewrite), so `AssemblyAITranscriber.transcript(from:enhanced:)` simply picks: with **enhanced
transcripts** on (`EnhancedTranscriptsStore`, on by default, read per request via the
transcriber's injected `enhancedTranscripts` closure) it prefers the rewrite and falls back to
`text` when `llm_response` is null or blank — the rewrite is best-effort (5 s server-side
budget), so a rewrite failure (`llm_error`) is a logged degradation, never a user-facing error.
With the setting off it returns `text`, and the rewrite that came back is discarded unread.

That ordering is deliberate and it has a price. **The route documents no way to decline the
rewrite**: it rewrites _by default_, omitting `llm_instruction` only selects the service's own
wording ("Omitting the field, or setting it to `null`, keeps the default cleanup task"), and the
escape the reference prescribes is exactly the one taken here — ignore `llm_response` and use
`text`. An explicit `"llm": null` _does_ suppress it (measured 2026-09-10, and the only off
switch there is; `llm: {}`, `llm: {"enabled": false}` and `llm_instruction: null` all run the
default instead), but it is **undocumented**, and Blurt sent it until 2026-09-11. What the move
costs is real: a user with the setting off still waits out the rewrite's server-side budget and
is still billed for a pass nobody reads. What it buys is one request shape rather than two, and a
switch that cannot disagree with the response it was applied to — the bug that shipped the other
way round, when "enhanced transcripts: off" returned a default-cleaned transcript anyway because
the config merely omitted the instruction.

The instruction is **chosen per rewrite mode** (`CleanupInstruction.sendable(appending:mode:)`):
Smart gets `smartText`, Fast gets `text`, and with enhanced transcripts off (no `rewrite_mode`
sent, so the service runs Fast) Fast's. `smartText` is `text` with two hand edits — keep
greetings and meaningful framing, delete "kind of" only as filler — that scored ZER 90.1 / 88.1
against 87.4 / 87.4 on the Voice Arena public set with that benchmark's own judge (Smart, two
samples each), and **worse** on Fast, which is why the two are not one string. Fast's
instruction is `CleanupInstruction.text`, the winner of a GEPA run of
`evals/dictation-prompt/` (see its README), compressed to fit the 2048-character cap the field
had at the time. Two later searches
failed to beat it — the most recent scored 0.9043 against its 0.9101 on a held-out split. When the
user has defined a **style profile** (`StyleProfileStore`, resolved at each press into
`PressStyle` and carried to the transcriber as `TranscriptionContext.styleInstructions`),
`CleanupInstruction.sendable(appending:)` appends that one profile's instructions after the base text with a bridging preamble, trimmed to
the per-profile editor limit (`StyleProfileStore.characterLimit`, 4000 UTF-8 bytes); no profile, or
blank instructions, sends the base instruction unchanged. A styled request leads with `CleanupInstruction.styledText` instead of
`text`: the base with its "preserve the original punctuation, capitalization, and spacing" rule
swapped for one that defers to the style — left as-is, that rule beat styles asking for no
capitals or commas. **Only the active profile's text ever goes on the wire** — never a
concatenation of all of them: the active profile is the style the user chose, and a join hands the
model several contradictory ones.

Note what that does and does not establish. It is the best instruction the harness has
produced, measured against other _text_ candidates on a _stand-in_ model; it has never been
shown to beat the service's default instruction, because the harness cannot score the service's own
rewrite model. On the one live comparison so far — two utterances through the real endpoint —
this instruction and the service default produced identical output. `--verify-live` settles
that with real audio. And every corpus behind it is English while the string ships to every
user in every language; pinning the _transcription_ prompt to English was reverted once
already. A revert here is one line: return nil and the key comes off the wire again — which
restores the service's own cleanup wording, not a verbatim transcript.

That field has **no length cap** any more. It was capped at 2048 characters, and over that the
API 400'd the whole request before reading the audio — a 3057-character eval winner shipped that
way once and broke all dictation. The reference now documents `llm_instruction` as a plain
`string | null` with no `maxLength`, and a probe on 2026-11-18 confirmed it: 2049 to 49152
characters accepted and applied, in Fast and in Smart. The one limit left is the service's on the
whole `config` part (64 KiB, undocumented), which the instruction plus one style profile stays far
below. The other fields still have caps of their own: 4096 on `config.stt_prompt`
(`STTPrompt.characterCap`, which the prompt builder fits the history and prior chunk into), and
on `config.keyterms_prompt` 2048 characters summed across all terms (`KeyTerms.characterCap`)
plus a cap that is a **count** and not a size:
at most 100 terms (`KeyTerms.termCap`, the reference's `maxItems`). The count is the one the
byte budget does not imply, and it is reachable, since 150 short terms cost ~1500 bytes and clear
the byte cap easily. Never reuse one field's figure for another, and never assume one cap on a
field is the only cap on it. Over any of them the API 400s the whole request before reading the
audio, so every dictation fails outright rather than degrading to the verbatim transcript.

The finished text arrives in the response body — no `/v2/upload`, no job submission, no polling.
The **upload is chunked**: `transcribe(frames:sampleRate:context:)` is called at _press_ and
streams the recording into one open request as the microphone produces it, so the transfer overlaps
the speaking instead of following it. Every dictation starts on this path — measured on a 1 Mbps
uplink, a 10 s dictation waits ~3.1 s after speech buffered versus ~0.5 s chunked, and on a fast link
the two are within noise. The only buffered request is [the over-cap fallback](#the-over-cap-fallback),
for a recording this route has refused as too long. The `config` part is written **first**, which the streaming route requires — it
cannot open its upstream STT call without it, and rejects an audio-first body with a 400 (whose
exact wording lives once, on `AssemblyAITranscriber.streamedBody`). That is
also where the rest of the win comes from: the service starts inferring as the audio arrives rather
than after the last byte, and nothing at all sits between the final frame and the request closing.
The cost is that the press-time context read has to be settled _before_ the request opens, so
`DictationSession.startUpload` awaits it (bounded by `contextWaitBudget`) instead of the release
path doing so — the read is dispatched before the mic bring-up is joined, so it is almost always
already finished and the wait is spent while the user is still speaking, not while they wait for a
transcript. The _response_
is unchanged and still arrives whole: a single `async throws -> String`, no deltas. The streaming
route accepts audio from ~80 ms up to **120 s** (server-side ~30 s inference deadline); the buffered
route accepts up to **20 minutes** / 256 MB. Blurt records for up to the buffered route's 20 minutes
(`RecordingLimits.maxAudioSeconds`, raised from 120 s in #251), and that cap backs
`DictationSession`'s auto-release timeout, so a held hotkey stops before it (at 1195 s).

#### The over-cap fallback

The SDK's `DictationClient+LiveCapFallback.swift`. The streaming route answers a recording that runs past
its 120 s cap with `413 {"error_code": "audio_too_large"}` — mid-upload, as soon as the cap is passed,
while the user may still be talking. Before this fallback, that 413 surfaced at release as
"Transcription failed: AssemblyAI error 413: audio exceeds 120000 ms" and everything said was lost —
on every dictation over two minutes once #251 raised the recording cap. Now:

1. The capture feed reaches the upload through `relay`, which keeps a copy of every audio byte, from
   the first, on the upload's own task — never under `MicCapture`'s capture lock.
2. Only `413` **and** `error_code == "audio_too_large"` triggers the fallback. Every other failure
   surfaces exactly as before, and the copy is dropped with the request.
3. On the trigger, `relay` keeps reading the feed until the recording ends (key up, or the
   auto-release), so audio spoken after the refusal is kept. The drain is recording time: it has no
   timeout of its own.
4. The whole copy goes to `POST /v1/transcribe` once, with the same `config` JSON, the same audio part
   (`audio.pcm`, `audio/pcm`) and the normal idle timeout, and its response takes the same path as a
   streamed one: rewrite or `text`, paste, history. The pill reads "Transcribing…" throughout. If it
   fails, its own error is what surfaces.
5. The copy is bounded by `DictationClient.maxBufferedAudioBytes` (the route's 256 MB); past it the
   copy is dropped and the fallback fails cleanly (`AssemblyAIError.recordingTooLarge`). At the
   capture geometry a 20-minute recording is ~38 MB, so this is a guard.
6. A cancel drops the copy and sends nothing.

`/v1/transcribe` is documented — <https://assemblyai.com/docs/api-reference/dictation-api/transcribe.md>
— which is what licenses calling it under "The reference is the source of truth". AssemblyAI's Python and
Node SDKs are getting the same fallback to the same spec. The alternative, if the copy isn't wanted, is putting
`RecordingLimits.maxAudioSeconds` back to 120, so the auto-release stops a held key just inside the
streaming route's cap; raising that cap server-side would make the fallback unnecessary.

Every wire constant was swept against the live route on 2026-09-09 (the keyterms list at 2048 chars and the
then-120 s audio ceiling were both exact and enforced — the streaming route's 120 s is enforced again
server-side since 2026-10-14, re-measured 2026-10-29 as a mid-upload 413 on 130 s of audio, while
`/v1/transcribe` answered the same 130 s with a 200; the prompt's 4096 is the API's own and hard-rejecting,
measured in Unicode scalars on 2026-09-10 — it was `conversation_context`'s 4096, which was **ours**
and merely trimmed, until `stt_prompt` replaced that field; the whole `config` part is separately
limited somewhere past 48 kB; sub-floor audio returns 200 with an
empty transcript rather than a 400; post-speech latency is flat from a 4 kB write to a single one, so
`ChunkedRequestBody.bufferSize` has nothing to gain from retuning). Each constant's own doc comment
carries its measurement — change one only against a fresh sweep, not against the old prose.

### `DictationSession` — `Sources/BlurtEngine/Pipeline/DictationSession.swift`

The central actor, split across `+Commands.swift` (command surface), `+Observation.swift` (phase
stream and signposts) and `+Pipeline.swift` (the post-release transcribe→inject run).

It exposes `press()` / `release()` / `cancel()` / `cancelRecording()`, a synchronous
fire-and-forget `submit(_: Command)` mirroring those four for callback-shaped hosts (commands run in
exact emit order — the tap wires straight into it, no per-callback `Task` spawning), and a
`phase: PipelinePhase` (`idle | starting | recording | transcribing | injecting | failed |
cancelled`, plus the terminal successes `pasted` / `noTarget` / `handedBack`). `press(handingBack:
true)` (`Command.pressHandingBack`) is the one variation: the same dictation, whose transcript ends
the run as `.handedBack(text)` instead of being pasted or remembered. Read-aloud's "ask about the
selection" and "rewrite the selection" are its only callers, and it rides the phase rather than a callback so the router sees the
transcript and the dictation's end in one order. `phaseStream()` yields the current
phase immediately then
every transition, and is **multi-observer** (one continuation per call), though hosts should still
render from one consumer and project the phase into their own state. Both coordinators subscribe
with `phaseStream(alreadyShowing:)`: the session skips the opening yield when it is still at the
phase the host renders, so a fresh session's `.idle` can't arrive after a press the host already
took and end that dictation (#413).

A host-supplied `readinessCheck` closure can refuse a press before any capture begins — the app
passes a key-presence check, so a missing API key surfaces as `.failed(.apiKeyMissing)` at press
time, never after the user has spoken. Its three collaborators are protocol-typed
(`MicCaptureProtocol`, `TranscriberProtocol`, `InjectorProtocol`) so tests stub them; see
`Tests/BlurtEngineTests/Stubs/`. The two that aren't protocols — the press-time focus capture and the
developer-mode log — ride on **`DictationSession.Seams`** (`+Seams.swift`), a value the internal
initializer takes and the public one fills with `.production`. Injectable for the reason the
protocols are: called as statics, the captured context's _value_ was whatever app happened to be
frontmost during a test run (so only its arrival could be asserted), every press paid a real AX
round trip, and the log wrote to the user's real `~/Library/Logs/Blurt`. STT errors that are already
`BlurtError` surface verbatim; others
are wrapped in `.sttFailed` — a `URLError.cancelled` included, unless the pipeline itself was
cancelled: a request the system dropped fails rather than leaving the phase on `.transcribing`, where
no press can start. The pipeline is just transcribe → inject, and an empty transcript returns to
`.idle` without injecting.

Four perceived-latency choices to preserve:

- `press()` claims `.connecting` _before_ `mic.start()`, so the pill answers the key-down while the
  mic is still coming up — but the **start chime deliberately does not**. `RecordingCueGate` keys on
  `.recording`, which `MicCapture`'s liveness gate only reaches once the input route is delivering
  frames, so the chime rides the connecting→recording edge by construction. That ordering is
  load-bearing, not cosmetic: the chime is a "speak now" cue, on a Bluetooth route it and the press
  are ~1–2 s apart, and speech in that window is **unrecoverable** (the OS receives nothing while the
  profile switch is in flight). Chiming at the press is what lost the first words of the utterance.
  Don't "fix" the chime to fire earlier.
- `.injecting` projects to `OverlayUIState.processing`, **not** `.idle` — the shell reads an idle
  projection as "dismiss", so mapping this working phase to idle faded the pill out mid-dictation and
  blinked it back for "Pasted".
- `release()` claims `.transcribing` _before_ `mic.stop()`, so the stop chime and pill switch fire at
  key-up rather than after the recording is read back. This ordering also closes the double-release
  window `ReleaseRaceTests` pins — and it is what lets `MicCapture`'s Bluetooth tail linger sit
  inside `stop()` without the user ever waiting on it.
- The press-time Accessibility context read is consumed with a bounded wait (`contextWaitBudget`,
  500 ms), so an unresponsive frontmost app costs the transcript its priming, never a multi-second
  stall.

### `KeyInjector` — `Sources/BlurtEngine/Injection/KeyInjector.swift`

`insert` always injects via clipboard paste: it saves the current pasteboard contents, writes the
transcript, then posts ⌘V (`CGEvent` to the `.cgAnnotatedSessionEventTap`, not the HID tap). It
returns once the paste is posted; the wait for the target to read the clipboard
(`pasteSettleDuration`, default 400 ms) and the restore of the prior contents run on a chained
follow-up task (`pendingSettle`), which also serializes back-to-back inserts so a second paste can't
snapshot the first one's clipboard. The whole paste, settle and restore included, is also one turn on
the pasteboard's `PasteboardLock`, shared with the read-aloud press's ⌘C fallback (`SelectionCopy`),
so a copy can't snapshot a settling paste's transcript as the user's clipboard, nor a paste's restore
land under a copy's poll (issue #341). ⌘V and ⌘C are posted on the key that types "v" / "c" with ⌘
held on the user's ASCII-capable layout (`KeyboardLayout`), falling back to the US key: macOS matches
a ⌘ shortcut by character, so the US V key is ⌘K on Dvorak and the US C key is ⌘V on Turkish-F.

The restore is deliberately conservative: `SystemClipboard.snapshot()` returns `nil` when the
pasteboard can't be read at all (distinct from it being _empty_), and `restore` builds the
replacement items before clearing, so a snapshot it can't reproduce leaves the clipboard alone
instead of emptying it. Promised (lazily provided) representations can't be copied, so restoring
those degrades to the plain-text floor rather than a byte-faithful round trip. A snapshot holding a
secret (`ConcealedType`) goes back kept to this Mac and with a fresh `concealedLifetime` expiry: the
clear that was due for it keyed on the change count before the paste, so it would now skip. Every
pasteboard write — the paste, the leave-behind, both restores, the expiry's clear — goes through one
private primitive, `SystemClipboard.put`, which counts the write as Blurt's own and gives a concealed
one its host-only scope, its markers and its expiry, so a new write path can't forget any of them.
The one concealed write it doesn't expire is a paste with a snapshot to restore: the restore takes
the words off.

It first activates the captured target app; if that app has terminated or won't activate, it leaves
the transcript on the clipboard and throws `.targetAppLost`, which the pipeline degrades to the quiet
"copied" notice (`.noTarget`) rather than a red failure. Consecutive dictations are joined with a
leading separator space via `InsertionSeparator.withLeadingSeparator` (its own platform-free type,
because a host that inserts text itself faces the same decision) — never after an opener such as
`(`, an opening quote, `@` or `$`, nor after a straight quote or `#` that starts a word; when the prior text is unreadable,
the separator basis falls back to what was last pasted — but only when the target app **and** window title both
match the last successful insert, so the fallback tracks "the same window", not just "the same
process" (a browser hosts many unrelated tabs under one PID).

### `AppCoordinator` — `App/Blurt/Blurt/AppCoordinator.swift`

The only place the engine is composed for the real app. It builds the concrete instances and owns a
`DictationKeyTap` whose `onStart` → `session.submit(.press)`, `onStop` → `submit(.release)`,
`onCancel` → `submit(.cancel)`, and `onRecordingDiscarded` → `submit(.cancelRecording)`, then
observes `session.phaseStream(alreadyShowing:)` to drive the overlay.

Any `PipelinePhase.setupBlocker` — today a missing API key — routes to the settings UI via its
`onSetupBlocked` closure instead of an error flash. Which failures count as unfinished _setup_ rather
than faults is the engine's single classification, so the shell's navigation and the pill's
calm-idle projection can't disagree. It also owns `hasAPIKey` (drives the wizard/Settings UI; the
press-time gate itself is the session's `readinessCheck`) and `saveAPIKey`, calls
`keyTap.ensureRunning()` to install/enable the tap (which returns false until the process is
Accessibility-trusted; `WizardController`'s permission poll then calls
`retryKeyTapInstallIfNeeded()` each tick while ready, so a failed install is retried until it
lands), and `keyTap.refreshBinding()` after the user picks a different trigger key.

## Hotkey

The triggers are **lone modifier keys**, each set to dictate, read the selection aloud, ask about it,
rewrite it, write from spoken instructions, or nothing, and each tapped, held, or either (see Keys below) — implemented in-house. Four pieces,
three of them pure engine logic:

- **`TriggerKey`** (`Hotkey/TriggerKey.swift`) — enum of the curated lone momentary modifiers usable
  as triggers (right ⌘, right ⌥, `fn`, left ⌘, left ⌥, left ⌃), `rawValue` = the macOS virtual
  keycode, plus `label` ("right ⌘") and the device-modifier masks the event source needs (one bit
  per physical side). Dictation defaults to right ⌘ because a solo press rarely collides with app
  shortcuts; left ⌥ defaults to reading aloud (not left ⌘, which is down for every shortcut and
  ⌘-click), and a read waits for the press to prove itself (below).
- **`TriggerKeyStore`** — persists the chosen keycode in `UserDefaults` (`BlurtTriggerKeyCode`),
  defaulting to **right ⌘**.
- **`DictationKeyGate`** — pure, clock-free state machine (`idle`/`armed`/`latched`) turning
  modifier-down/up and other-key-down into `start`/`stop`/`cancel`/`none`. Recording starts the
  instant the modifier goes down; what a key-up means is the **`TriggerActivation`** every key
  shares (`TriggerKeyBindings.activation`, from `TriggerActivationStore`, default tap-or-hold —
  one mode for all keys, owner-directed 2026-11-04, after per-key modes were tried): under tap-or-hold a release ≥ `holdThreshold` (default 1 s) is a **hold**
  (push-to-talk → stop) while a shorter release **latches** (tap-to-toggle; next tap stops);
  tap-only latches on every release, hold-only stops on every release. A combo
  (modifier + another key, e.g. ⌘C) from idle cancels the fresh capture; over a latched recording it
  passes through as a normal shortcut. Callers pass monotonic timestamps, so every decision is
  deterministic and unit-tested.
- **`DictationKeyRouter`** — the event-routing layer over the gate: only the bound keycodes' flag
  changes drive the modifier (the first to go down owns the gate, `activeKeyCode`, until it is idle), and only genuine down/up **edges** reach the gate (`flagsChanged`
  deliveries re-report the bit whether or not it changed, so a repeat must not double-fire).
  A press from idle rebuilds the gate under its own key's mode, so each key keeps its own.
  `reset()`/`rebind(activations:)` report whether they discarded a live recording the host must
  cancel upstream, and so does **`recoverFromDroppedEvents(heldFlags:)`** — the
  disabled-tap rule: events may have been dropped, so the gate's state survives only while the
  active trigger is still physically held (its key-up is still coming); otherwise that key-up was
  among the losses and the gate is reset. The host passes the raw `CGEventSource.flagsState` read
  in — the router picks the active key's device bit out of it — and
  keeps no decision of its own, so the rule is unit-tested rather than living in an untestable
  shell `if`. It also routes an Escape — `Event.fromKeyDown`: keycode 53, not a key-repeat, its switch on —
  arriving as `.escapeDown(rawFlags:)`. The app passes the switch as `EscapeCancelStore`
  (`BlurtEscapeCancelsDictation`, off by default, the Advanced pane's Experimental section), read at
  the keystroke and only for an Escape; off, the event is `.keyDown(53)`, so Escape takes the
  ordinary-key path exactly as on main and nothing else is asked. Only a **bare** one counts: no ⌘⌥⌃⇧ beyond the held trigger's own
  generic bit (an Escape over a held right ⌘ carries `maskCommand`), and not with that trigger's twin
  held too, so ⌘Esc with both ⌘s and ⌥⌘Esc stay shortcuts. The router decides it, since only it knows
  which trigger is held. A bare one is a discard only with the gate live or the host's `inFlight` (`handle(_:at:inFlight:)`, what the gate can't see: a dictation
  past its recording, a request, a job, a read) true, since the tap is listen-only and sees every
  Escape on the system: the router `reset()`s — gate, `modifierIsDown` and `activeKeyCode` — so another
  key works at once, and returns `.discard`, the one action that means it. Any `reset()` remembers a
  trigger still held through it (`heldThroughReset`): its re-reported down bit and its key-up are
  inert until it is let go, or the re-report would read as a fresh press and start a new dictation —
  after a discard, and again at the `syncAfterTerminalPhase` reset the discarded dictation's end
  brings. Dropped-event recovery checks it against the held flags, since its release may be lost. Otherwise the ordinary-key path again.

The app side, **`DictationKeyTap`** (`App/Blurt/Blurt/Hotkey/DictationKeyTap.swift`), reduces each
`CGEventTap` delivery (watching `flagsChanged` for the bound modifier and `keyDown` for any other
key) to a `DictationKeyRouter.Event` and owns the tap lifecycle. `AppCoordinator` calls its
`syncAfterTerminalPhase()` on every terminal phase: a dictation can end with no key event to close
the gate (the auto-release cap, or a refused/failed press), which would leave the gate `.latched`
and silently swallow the user's next press — a latched `modifierDown` returns `.none`, and the
`modifierUp` after it returns `.stop`, which no-ops on an already-terminal session. An Escape's
`inFlight` is the read-aloud router's `isBusy` (its own mode, or the session busy), and the tap maps
`.discard` to `SelectionSpeechRouter.escape()` and `.cancel` to a combo's `submit(.cancel)`, deriving
nothing from the event itself. `escape()` stops, from every routing mode, the router's own work — a job before it
pastes, a read or answer, a request — and cancels a busy session, which a combo would leave running
under a press still deciding. With nothing of the router's under way the cancel goes to the session
unconditionally, and `DictationSession.cancel()` decides by its own phase (a no-op at rest), so a
stale "in flight" can't strand a dictation. The ready screen's own hidden Esc button cancels as on main
whatever the switch: it also answers ⌘-period, which the tap never routes, and with the tap's Escape
on, its second cancel lands on a session the first already ended, where `cancel()` is a no-op. The
tap **swallows nothing**: a lone modifier types nothing, combos pass through so normal shortcuts keep
working, and the Escape cancel does **not** consume the keystroke — Escape still reaches the focused
app. Making it exclusive would require an active (`.defaultTap`) tap, which is ruled out because
macOS would then block on this process for every system-wide keystroke.

Because the tap can't swallow `fn`, macOS's own 🌐 action ("Press 🌐 key to": emoji, input source,
or Apple Dictation — each with its own sound or popup) would fire on every `fn` dictation. The
engine's **`GlobeKeyOverride`** handles that: while `fn` is bound, `AppCoordinator` (at `start()`
and on every rebind) sets `com.apple.HIToolbox` `AppleFnUsageType` to 0 (Do Nothing), and binding
any other key restores the value it replaced. That record lives in a suite both builds share
(`dev.alex.blurt.globe-key`) — the setting is one per login, so a per-host record let Blurt and
Blurt Dev restore each other to Do Nothing — and outside `DefaultsKey` on purpose, so a settings
reset doesn't erase it: the relaunch after a reset is what restores the user's setting.
`scripts/reset-lib.sh` (behind `reset-install.sh` and `reset-dev-install.sh`) restores from it directly, since it wipes the host domain; if the other build still binds `fn`, its next launch re-applies the override. The write
only takes effect at the next log-in (macOS reads it then), so until then `fn` may also open the
emoji picker or Apple Dictation. A keycode 63 saved before `fn` was removed (#146) is migrated to right ⌘ once
(`TriggerKeyStore.migrateStaleFunctionBinding()`), so restoring `fn` doesn't silently rebind it. Don't fix this with an active tap that swallows `fn`: the tap is listen-only for latency.

The keys are editable on Settings' Keys tab (`KeysSettingsTab`; below); after any change
`AppCoordinator.dictationBindingChanged()` re-reads the binding into the tap. Every reader of the
keys — the tap, the read-aloud router, `PressStyle`, every view — goes through one snapshot,
**`TriggerKeyBindings`** (`TriggerKeyBindings(defaults:)` for one-shot reads), which owns the
defaults and the rules; views that must re-render live on a Settings change use
**`@ObservedKeyBindings`** (`Wizard/ObservedKeyBindings.swift`), which observes the four raw slots
through `@AppStorage` and builds the snapshot from them. The unset defaults belong to the bindings
(an absent keycode maps to right ⌘), so views must not restate them.

**Keys.** Settings' Keys tab, after General (`KeysSettingsTab`), has one row per action
(`TriggerKeyChoice` minus Off) — dictate (with the main window's style, no custom style, or each
profile; the styles disabled while enhanced transcripts are off), Read Selection Aloud, Ask About
Selection, Rewrite Selection, Compose From Instructions, Control Your Mac — each with a pop-up choosing its key or None
(`TriggerKeyStyleStore.assign(_:to:)`: a key does one thing, so choosing one in use moves it, and
the Dictate row's key becomes the bound key), then one Activation pop-up for every key. Each key's start/stop cue voice is the Sounds tab's, after Keys
(`SoundsSettingsTab`): one row per key that isn't Off. `TriggerKeySoundStore`
(`BlurtTriggerKeySounds`, keycode → pack id) holds the ones set; a key with no entry plays its
action's setting (`SoundPackStore.fallback(for:)`, over the engine's `TriggerKeyAction.cue` —
read-aloud's, Control Your Mac's, or dictation's for every recording action), so an untouched install sounds as it did before keys had
voices. `CueSoundPlayer` keeps a pair per key and plays the one whose press started the recording
or read (`AppCoordinator`'s `onStart` tells it first). How read-aloud sounds (voice, speed, skipping jargon —
`ReadAloudStyleStore`) is its own Settings tab, Read Aloud, before Styles (`ReadAloudSettingsTab`);
picking a voice plays a sample of it, as picking a cue sound does. Its own tab, not rows on General,
because General has to stay short enough for a small display (three per-key rows pushed the
cue-sound picker off CI's screen).
`TriggerKeyStyleStore` (`BlurtTriggerKeyStyles`, keycode → choice, the stored form a style id had
before read and ask, encoded through `TriggerKeyMap`) and `TriggerActivationStore`
(`BlurtTriggerActivation`) are the writes; the action rows are a view over the keycode map. An
absent choice is the key's default — the bound key dictating with the current style, left ⌥
reading aloud, the rest off — so Off is stored explicitly where it isn't the default. Every
row offers None, Dictate included (owner-directed, 2026-11-06), so no key need dictate. The one
rule `TriggerKeyStyleStore.setChoice` keeps is that while any key dictates, the bound key
(`TriggerKeyStore`, the one the ready screen and menu bar name — `TriggerKeyBindings.dictationKey`)
is one of them: taking the bound key off dictation moves the binding to the next dictating key
first, and with none it stays put and nothing dictates, until the first key set to dictate again
takes it. With no dictation key, the main window's Dictate row reads None, and the menu bar, the
empty Library and the permissions step point to Settings › Keys rather than name a key. A key's entries mean the
same in either role, so moving the binding moves nothing else. Changing another key doesn't reset
the router, so a recording latched while Settings is open survives it. The press command carries its key
(`DictationSession.Command.press(key:)`), and the session resolves that key's style once, on the
press's own turn, into a `PressStyle` value: its instructions ride the request's context, its name
the Recent row. It never writes `BlurtActiveStyleProfile`, a later press can't restyle a dictation
under way, and a mapped style since deleted falls back to the selection.

**Read aloud and ask** live in the engine: `SelectionSpeechRouting` (pure) decides, and
`SelectionSpeechRouter` (main-actor) carries it out — the selection read, the hold timer, the speech
task — reporting each read's start, end, loudness and failure to the app, which owns only the pill,
the cues and the beep. A dictating key's commands pass straight to the session, so dictation
never waits on an Accessibility read. A read or ask press reads the selection, and nothing starts at
the key-down — a modifier going down over a selection is as often the start of ⌘C — until the press
proves itself: a tap (the gate's `.latch`), or the key still down `holdDelay` (350 ms) later in a
mode that holds. A combo before then does nothing. A read then plays until the key's next stop; an
ask records like a dictation (`pressHandingBack`) and the transcript handed back is answered aloud.
With nothing selected, the press does nothing. A read or answer wears the dictation pill
(`OverlayUIState.speaking`: the orb and meter, the meter following the voice — `StreamingPCMPlayer`
keeps each chunk's 50 ms loudness windows on the media timeline, `PCMLevel`, and the meter reads the
one playing) between its own start and stop cues (read-aloud's `SoundPackStore` slot). While a read
plays, only a new capture takes the pill (`PipelinePhase.overlayState(whileSpeaking:)`); when it ends,
the pill goes back to a steady state still under way and never replays a dictation's old notice
(`overlayStateAfterSpeech`). Each cue pair reloads after an output-route change on its own schedule
(`CueReprimeSchedule`): dictation's at the next press or terminal phase, read-aloud's at once unless a
capture is running. `SelectionSpeechRouter` takes any `ReadAloudSpeaker` (`SelectionSpeaker` in
production), which is how the UI tests run read and ask offline; a stopped read's cancelled request
reads as a cancellation, never a failure (and a request the system dropped, which nobody stopped,
as a failure). The voice comes through the engine's
`SpeechSynthesizing` seam (`SpeechServices.synthesizer`), and Blurt's is AssemblyAI's documented
Streaming TTS API (`BlurtAssemblyAI`'s `AssemblyAISpeechSynthesizer` over the SDK's `SpeechClient`:
`POST https://tts.us.assemblyai.com/v1/speech`, `voice_id`, the audio read as the response streams).
Every LLM client below sends through the engine's `GatewayConnection` (a `ChatCompleting` the host
supplies: AssemblyAI's LLM Gateway, through the SDK's `GatewayChatClient`). A selection is read in pieces (`ListeningChunks`: a short first
piece, so reading starts after a paragraph, then about 1,500 characters each, at paragraph or
sentence ends, cut where the provider says its voice reads a cut best —
`SpeechSynthesizing.sentences(of:maxCharacters:)`, the SDK's `SpeechSegmenter` on AssemblyAI), one request each, rewritten first when skip-jargon is on; the next piece is asked
for only once less than 30 s of audio is queued (`SelectionSpeaker.bufferTarget`), so a long
article (up to 100,000 characters) starts quickly and is synthesized only as far as it is heard;
the voices offered are the provider's (`SpeechSynthesizing.voices`): on AssemblyAI the English ones on
the docs' Voices page (`BlurtAssemblyAI`'s `ReadAloudVoice.assemblyAI`), since a read sends no
`language` and a catalog voice would otherwise speak its own. The setting stores a voice id, or none
for the provider's default, and the provider speaks its default for an id it doesn't list.

**Rewrite** rides the same routing as ask, up to the hand-back: a rewrite key's press reads the
selection, records a spoken instruction ("make it more formal") with `pressHandingBack`, and the
transcript handed back goes to `SelectionRewriting` (`SelectionRewriter` in production: one chat
completion on Gemma, `gemma-4-31b`, the file transcripts' model) with the selection, instead of to the
speaker. The rewrite is pasted over the selection by `DictationSession.replaceSelection(with:)` —
the session's own injector, so it queues behind a dictation paste still settling, aimed at the app the
hand-back press captured, with no separator. It wears the pill as `OverlayUIState.rewriting`
("Rewriting…") and then the notice a dictation ends with: Pasted, Copied (nothing editable focused,
the rewrite left on the clipboard), or the error. Any press abandons a rewrite before it pastes, as
it stops a read. A selection past `SelectionRewriter.maxCharacters` (20,000) fails rather than
rewriting a part, since the paste replaces all of it, and a reply cut off at the token cap is never
pasted. No key rewrites by default; rewrites aren't kept in the history.

**Compose** is rewrite with no selection: a compose key's press skips the Accessibility read, as a
command's does (`.selected` from the key-down, still proving itself by a tap or a hold before the
mic opens), then records spoken instructions — "ok, a Slack reply to Dan: we should have a feature
to just speak instructions, keep it casual" — with `pressHandingBack`. The transcript handed back
goes to `MessageComposing` (`MessageComposer` in production: one chat completion on Gemma, the
rewrite's model) with the name of the app the hand-back press pinned as its paste target
(`DictationSession.pinnedAppName` — not whatever is in front once it's transcribed, so switching
apps meanwhile can't get an email pasted into Slack; never the window title or any field's text), so the instruction can fit the writing to it — a chat message for Slack, an email
for Mail. It is pasted the way a rewrite is (`replaceSelection(with:)`: the hand-back press's
target, no separator, over whatever is selected, else at the cursor), wears the pill as
`OverlayUIState.composing` ("Writing…") and then the same notices, and shares the router's job
lifecycle, so any press abandons it before it pastes. A reply cut off at the token cap
(`MessageComposer.maxTokens`) is never pasted. No key composes by default; compositions aren't kept
in the history.

**Control Your Mac** rides the same hand-back, with no selection: a command key's press skips the
Accessibility read (it is `.selected` from the key-down) but still proves itself by a tap or a hold
before the mic opens, then records a spoken command with `pressHandingBack`. The transcript and a
`ScreenContext` go to `VoiceCommandPlanning` (`VoiceCommandPlanner` in production: one chat
completion on Gemma, `gemma-4-31b`), whose reply is a JSON plan of at most ten steps from a closed
list (`VoiceCommandStep`). The context is read from the Accessibility tree, never a screenshot, so it
needs no Screen Recording permission: `SystemVoiceCommandPerformer.screenContext()` walks the frontmost
app's focused window breadth first (at most 3,000 nodes, `ScreenSnapshot.entries`), keeping up to 150
actionable elements — buttons, links, checkboxes, pop-ups, text and search fields — each listed as
`[n] kind "label"` (`ScreenContext.promptText`; a label kept on one line inside its quotes, so page
text can't pose as another element). Labels only: a field's contents are never read, and a password
field is never listed. The numbers are that snapshot's own (`ElementSnapshot`): a `press` or `focus`
step naming one the snapshot didn't list refuses the plan, and one acted on after the frontmost app
changed fails as "the window changed" rather than acting on whatever is now there. The instruction
tells the model the labels are on-screen content, never instructions: the window block's opening
and closing tags carry a fresh random fence code per request, and `ScreenContext.quoted` turns every
line break, control and format character (`\r`, U+2028, zero-width, bidi) into a space, a quote into an
apostrophe and `<` `>` into guillemets, so a label can neither start a new element line nor write a
tag. The request sends a strict JSON-schema `response_format` (`VoiceCommandPlanner.responseFormat`), one `anyOf` branch per action requiring that action's own fields (with every field optional, "close this tab" came back as a shortcut with no keys; the gateway enforces `anyOf`, measured 2026-11-03):
gemma-4-31b follows it on the gateway, measured 2026-11-03 — the same request without it came back as
prose, a fenced bare array and an element named by its label. The tolerant parser stays behind it, and
a plan it can't use (a malformed reply, an unknown action, key or element) is asked for once more with
the model's own reply and the error (`VoiceCommandError.isRetryable`); an empty plan is the model's
own answer and is never retried. The instruction ranks a listed element first, then a known shortcut,
then a real menu item (never an invented path), then `press_button`; lets element steps chain until the
first step that brings another app, window or tab forward; limits refusal to the four destructive
actions; and ends with seven worked examples, one of them a refusal. What one app needs — Google Docs' paragraph styles, Slack's ⌘K
switcher, Terminal's View › Bigger — is not in that instruction but in `AppNotes`: a short note per app,
sent in an `<app_notes>` block of the user turn only when the app is in front, is the web app in the
front browser window (matched on its window title, " - Google Docs"), or is named in the command.
Kept in the base instruction, each app's advice reached every other app's plans (Docs' "normal text"
became a find-and-select, 2026-11-04); moved out, Docs went from 19 to 30 of 30 on the eval.
`promptVersion` hashes the notes with the instruction and schema, and the planner eval reports a pass
rate per app. After parsing, an `open_url` that is only an installed app's name — `slack.com`, a web
search for "Slack" — on a command that never asked for the web opens the app instead (`AppLink`):
however the instruction was worded, the model kept sending "switch to Slack" to the browser. A link
opens in the browser in front when one is, never the default browser behind it. A plan that repeats
one step more than its limit, or a group of different steps back to back, is a loop and is asked for
again. A window holding a web page
(Chrome, Safari, an Electron app) is read in two walks so the page gets 100 of the 150 slots rather
than the tab strip and bookmarks bar (`ScreenSnapshot.webShare`); a page with fewer than five listed
elements is read again after 300 ms and 600 ms, since Chrome builds its tree only after a client first
reads a role; elements scrolled out of view are dropped; and a pressable `AXGroup` (a web page's
clickable `<div>`) is listed as "clickable", its name borrowed from its `AXTitleUIElement` or its
text. Every call is capped at 0.25 s and each walk at 500 ms. An Electron app (an `ElectronAsarIntegrity`
key in its Info.plist) gets `AXManualAccessibility`, once per process. A Chromium browser
(`ScreenSnapshot.chromiumBrowsers`) doesn't implement that switch (`-25205`) and builds no page tree at
all without `AXEnhancedUserInterface` — measured on Chrome (2026-11-03): 47 nodes and no web area, then
a full page about 2.1 s after the flag goes on, torn down at once when it's cleared. That flag also
slows window managers' moves and resizes, so it's scoped to the command: set the moment a command
press proves itself (`VoiceCommandPerforming.commandStarting`), so the build runs while the user
speaks; cleared when the command ends (`commandEnded`), or 30 s on for a press that asked nothing; and
never touched when another tool already had it on (`EnhancedInterface`). A `focus` on a single-line field (text,
search, combo box) selects its whole contents once it's confirmed focused, by its length
(`AXNumberOfCharacters`, never its text), as tabbing into a field does, so a typed step replaces it — a
focus alone left Chrome's address bar caret mid-URL and the paste landed inside the old address. A
field that won't take the range keeps its cursor rather than getting ⌘A, which would select whatever
has focus; a text area keeps its cursor. Which roles are text entries, whose value is their name, and
which a step may select or adjust are one list each in `ScreenSnapshot`, as are the rules for listing
and labelling a node, so the tests cover them; the shell (`SystemVoiceCommandPerformer*.swift`, one
pattern in the coverage gate) only makes the calls. A read that still finds no
web area waits up to 2 s more for it. Every element a read touches is capped at 0.25 s a call
(`AXRead.capped`; the default is 6 s), and the web-area search at 250 ms in all: Music answers at about
15 ms a call, and an unbounded search of its window took 19 s (2026-11-03); bounded, the read is 0.8 s
and still lists its sidebar. Rows are listed by the text inside them, never an icon's symbol name. A walked element's common attributes
(role, subrole, frame, title, description, placeholder, children, title element) come in one
`AXUIElementCopyMultipleAttributeValues` round trip (`AXRead.Node`); its `AXValue` is read on its own,
and only for a role whose value is its name (a link, a static text, a pop-up's choice) — never a text
entry's, which is what the user typed. Measured 2026-11-03: that halves the calls where an app answers
fast (Music's sidebar, ~1 ms a call), but Music's content area answers at 26–130 ms a call whatever is
asked, so its read stays bound by the budget at the toolbar and sidebar; the row-name lookup takes the
walk's deadline too, so one slow row can't outrun it. The read starts the moment the command's recording ends
(`SelectionSpeechRouting` emits `.readScreen` as it moves to transcribing, by tap or by letting go),
so it runs while the command transcribes rather than after it; `.runCommand` plans with that read,
reading only if there was none (the recording cap handed it back with the key still down). A longer
budget doesn't buy a slow app more: at 1 s, Music still listed only its toolbar and sidebar, its
content rows under groups that take seconds to walk, so the walk budget stays 500 ms.
`select` sets a row's `AXSelected` (a click when it won't take it), `set_value` / `increment` /
`decrement` change only sliders and steppers — text still goes in by `focus` and a pasted `type` —
and `window` sets the focused window's `kAXPosition` / `kAXSize` from `WindowLayout`. An app that is
frontmost but never owns the top window (its window on another Space) is in front enough; only one
that never comes forward fails the command. Each plan is logged at info level — the app, the element
count and the steps by kind (`VoiceCommandStep.logName`), the command itself private. A press that `AXPress` refuses,
or a focus the app doesn't take, falls back to a real click at the element's centre (scrolled into
view, inside its window, its app still in front, the pointer put back). In a Chromium browser or an
Electron app (`checksPress`) so does a press — or a row's `AXSelected` — that reports success but
changes nothing Blurt can see 250 ms later (`PressFingerprint`: the focused element, the window title,
the element's value, whether it's still on screen), because Chrome answers success for a press its
page ignored, and Slack and VS Code take `AXSelected` on a sidebar row and open nothing. That was
owner-directed (2026-11-03), knowing the cost there: a control that worked without visibly changing
anything is pressed twice. A native app's success is trusted: checked everywhere, every Calculator
key went in twice (2026-11-04). A `menu` step the app's menu bar doesn't have is looked for in the page —
a web app's own menus, such as Google Docs' File, Edit, Insert and Format — each title pressed in turn,
its menu given 400 ms to open (`choosePageMenuItem`); an `AXExpanded` that changed counts as the press
working, so a menu title isn't clicked shut again. One step that doesn't parse — an unknown action or key, a link that isn't
`http`, `https` or `mailto` — refuses the whole plan, and a reply cut off at the token cap is never run.
The router then performs the steps in order through `VoiceCommandPerforming`
(`SystemVoiceCommandPerformer`: `NSWorkspace` to open, hide and quit apps — matched by name,
`NameMatch` — and to open links; a synthesized key chord on the annotated session tap, as the
paste's ⌘V is; system-defined media-key events; and, through Accessibility, `AXPress` on a button
found by name in the frontmost window, breadth first over at most 3,000 elements (`ElementSearch`),
or on a menu-bar item by its path, pressed without opening the menu). A chord's character key is
resolved on the user's own ASCII-capable layout (`KeyboardLayout`, `UCKeyTranslate`) so ⌘K is K on
Dvorak or AZERTY, falling back to its US position. An opened app counts as in front only once it is
active and owns the topmost normal-layer window (`isVerifiedFrontmost`, `WindowOrder`); until then
each 100 ms look asks again with `activate()` and raises it through `kAXFrontmostAttribute`, since
macOS 14's cooperative activation drops `activate()` from an app that isn't active itself, and
Blurt never is. One that isn't in front after 5 s fails the command rather than sending the next
step to the wrong app. `DestructiveGuard` refuses ⌘+delete chords and ⌘⇧Q / ⌥⌘⇧Q (Log Out) at parse time and a button or menu
item that deletes, trashes, erases, shuts down, restarts or logs out once matched on screen — the
prompt's ban, in code. A `type` step is pasted by
`DictationSession.typeText(_:)` through `InjectorProtocol.insertAtFocus`, which pastes where focus is
now — an earlier step may have brought another app forward — without touching the press's pinned
target, so it can't race the next press pinning its own. Rewrite, compose and command share one job lifecycle
in the router (`job`, `jobPill`, `.stopJob`, `Mode.working`, `processingState`), and the state machine
itself emits `.prepareCommand` the moment a command press proves itself. Every Accessibility action
on an element goes through `performAction(_:on:)`, which runs the destructive guard first. The pill reads `OverlayUIState.commanding` ("Working…")
from release to the last step, then `.done` ("Done"), Copied (a typed step with nothing editable
focused, which ends the command), or the error, the app named on the pill when it isn't installed or
open. Any press abandons a command before its next step. No key takes commands by default.

## Contextual prompt and key terms

`Sources/BlurtAssemblyAI/STTPrompt.swift` builds the string passed as the dictation
request's `config.stt_prompt` — it steers the _transcription_, not the LLM rewrite (that's
the request's separate `llm_instruction`). It's unit-tested in
`Tests/BlurtEngineTests/STTPromptTests.swift`.

**It reads exactly two fields of `TranscriptionContext`**, and joins them with a newline in this
order:

1. `recentTranscripts` — the user's own recent dictations, oldest first, from the session's
   `RecentDictations` ring. A stretch of dictation therefore reads to the model as one continuing
   passage instead of N unrelated clips.
2. `priorText` — the text immediately before the cursor, **last**, because it is what the
   utterance most immediately continues from: the sentence the caret sits in. So vocabulary,
   capitalization and mid-sentence continuity carry over from what is already there.

**This field is `config.prompt` under its other name.** The service rejects a request carrying both
— `provide only one of stt_prompt or prompt; they are the same field` — so `stt_prompt` is a name,
not a second parameter, and the older `conversation_context` (an ordered array of turns) is what it
replaced. Both of those still work and can ride the same request, measured, so the swap is a choice
about which one steers rather than something the API forced; sending the turn list too would put the
same prior text on the wire twice.

What the swap accepts: a custom prompt replaces the service's managed default transcription prompt,
and the API documents `config.language_code` as ignored whenever one is set. The language half was
re-measured on 2026-09-10 — a Spanish clip came back in Spanish with an English prompt, a Spanish
one, and none at all — so detection survives in practice, and the request still sets no language.
What it carries is prior text and nothing else: no `Previous transcript:` heading and no fixed
instruction, since the field is documented as a description of the audio rather than a command, and
the service applies its own transcription behaviour on top. That heading-plus-instruction shape is
what `conversation_context` was introduced to replace; don't bring it back with it.

Nothing else about the user's screen is on the request. The frontmost app name, the window title,
the focused field's label and the selected text are still captured — they drive paste spacing, the
injector's window identity, and the developer-mode log — and they stay on the machine. The app /
window / field hints, the `Selected text:` block, and the inline `Keywords:` clause the old prompt
used to carry were deleted, not switched off; see
[Settled decisions](./AGENTS.md#settled-decisions--dont-reintroduce-these).

`text(context:)` returns `""` when there is neither history nor prior text, and an empty string omits
the field so the model works from the audio alone. One cap applies, enforced here rather than assumed
of the caller: 4096 across the whole string including the newlines that join it (`characterCap`),
fitted by dropping the **oldest** entries first — the end `conversation_context`'s server-side
trimming dropped, so the swap didn't change which end of the history matters. There is no longer a
turn cap: `recentTurnCap` (99) answered to `conversation_context`'s 100-turn maximum, which this
field has no equivalent of, so one knob replaced two. The kept entries are a contiguous newest run:
an older one that doesn't fit is dropped whole rather than half-sent, since a truncated entry reads
as how the speaker actually talks. The one exception is a single entry longer than the whole budget
with nothing newer kept, which is clipped to its _tail_ rather than dropped — nearest the cursor is
what the utterance continues from.

**The cap is the API's now, and it rejects rather than trims.** `conversation_context` was documented
as trimming an over-cap list, which made our 4096 a bandwidth measure; `stt_prompt` answers 4097 with
`400 stt_prompt: String should have at most 4096 characters` before the audio is read, so `fitted` is
what stands between a long history and every dictation failing. Its unit is **Unicode scalars**,
measured rather than inferred from the word "characters": 4096 `é` (8192 UTF-8 bytes) is accepted,
while 820 family emoji — 820 grapheme clusters but 4100 scalars — is rejected. So Swift's
`String.count` would under-count and let a 400 through, and the UTF-8 bytes `KeyTerms` and
`CleanupInstruction` count (their own servers' units being unmeasured) would needlessly halve the
budget for accented text. Two omissions are deliberate and regression-tested — no language directive
and no filler-word clause; see
[Settled decisions](./AGENTS.md#settled-decisions--dont-reintroduce-these).

**The key terms are the request's other steering field.**
`Sources/AssemblyAI/Dictation/KeyTerms.swift` sends the user's Settings list as
`config.keyterms_prompt` — keyterms prompting: a flat array of strings biasing recognition toward
those exact spellings. It is a
sibling of `stt_prompt`, not an alternative; the API takes both on the same request and
they do different jobs (prior text versus a vocabulary list), which is why the
`Keywords: a, b, c.` clause was the wrong shape for the same intent. `keyterms_prompt` is the
canonical name — the one the other STT surfaces use, the one the dictation reference documents, and
the one the route's own validation lists first — with `keyterms` and `word_boost` kept as legacy
aliases. This sent `word_boost` until 2026-09-10, on the belief that it was the documented name and
`keyterms_prompt` merely one of the unknown fields the endpoint forwards as-is; measurement killed
both halves of that, since `/v1/transcribe/live` rejects an unknown key outright
(`Extra inputs are not permitted`) and `keyterms_prompt` returns 200. Send exactly one of the three,
never two — they are mutually exclusive on this route (`provide only one of keyterms_prompt,
keyterms, or word_boost`, 400 before the audio is read), so a rename here is a swap and never an
addition. `KeyTerms.fitted` takes whole terms in the user's order while
they fit the field's own 2048-character cap (`KeyTerms.characterCap`, measured in UTF-8 bytes —
the conservative reading, as with `CleanupInstruction`) **and** the list stays within
`termCap` (100), the reference's `maxItems` on the same field — two independent limits, so both are
checked; a comma-split list of 150 short terms clears the byte cap and 400s on the count. It returns a plain `[String]`, not an
optional one — the repo bans optional collections, and "no terms" needs only one spelling — so the
omit-vs-`[]` distinction that _does_ matter to the API lives in `DictationConfig.encode(to:)`, which
drops the key for an empty list. Terms arrive already trimmed and deduped from `KeyTermsStore.parse`,
so length is the only thing enforced here. Unit-tested in
`Tests/BlurtEngineTests/KeyTermsTests.swift`.

**The two fields are deliberately different JSON types, and neither tolerates the other's.**
`stt_prompt` is a string — an array earns `400 stt_prompt: Input should be a valid string` — while
`keyterms_prompt` is an array even for a single term. `DictationConfig.encode(to:)` is where that and
the omit-vs-`""`/`[]` rule live; `KeytermsWireTests` pins both, in both directions.

## Settings, persistence, and cues

**`HostIdentity`** comes first, because most of what follows is namespaced by it: the Keychain
service the API key lands in, the `os_log` subsystem (and the engine's dispatch-queue labels), the
`UserDefaults` prefix every `DefaultsKey` composes with, the `~/Library/Logs` directory the
developer-mode logs go to, the product name update alerts say, and the GitHub release the update
check reads. These were hard constants, which made them Blurt's with no opt-out — a second app
embedding the engine wrote into _Blurt's_ Keychain item, log directory and defaults keys. They are
one value now; `HostIdentity.current` is what the engine reads, `.blurt` is what an unconfigured host
inherits, and `BlurtApp.init` calls `HostIdentity.configure(_:)` because the identity belongs to the
host, not the engine — with `.blurt` or `.blurtDev` depending on the running bundle id, the two
differing only in the Keychain service (see
[Dev builds are a separate app](./AGENTS.md#regenerating-and-installing-the-app)). It is process-wide rather than
injected for the obvious reason: its readers are `static let` loggers, an enum of defaults keys and a
Keychain facade, none of which a caller constructs. The derivations are pure functions of the value
(`defaultsKey(_:)`, `logURL(_:)`, `queueLabel(_:)`, `logger(_:)`) so the tests exercise them against
a constructed identity instead of mutating the shared one, which every suite reads in parallel.

Engine-side stores, all `UserDefaults`-backed value types with the same shape:

- **`TriggerKeyStore`** (`BlurtTriggerKeyCode`), **`SoundPackStore`** (`BlurtSoundPack`),
  **`KeyTermsStore`** (`BlurtKeyTerms`, the user's domain vocabulary, re-read at every press via
  the session's `keyTermsProvider` and sent as the request's `keyterms_prompt` list —
  see `KeyTerms`),
  **`DeveloperModeStore`** (`BlurtDeveloperMode`, off by default),
  **`EnhancedTranscriptsStore`** (`BlurtEnhancedTranscripts`, **on** by default — unset reads as
  enabled; picks the cleanup rewrite over the verbatim transcript in the dictation _response_,
  re-read at every request — it shapes no part of the request),
  **`RewriteModeStore`** (`BlurtRewriteMode`, `RewriteMode.smart` by default — unset or unknown
  reads as Smart; Smart sends `config.rewrite_mode: "smart"` for the larger rewrite model, Fast
  omits the key so a Fast request is unchanged from before the setting existed, and nothing is
  sent while enhanced transcripts are off; re-read at every request),
  **`StyleProfileStore`** (three keys: `BlurtStyleProfiles`, the JSON list of up to
  `profileLimit` (4) named `StyleProfile`s; `BlurtActiveStyleProfile`, the id of the one in
  effect, or the `defaultStyleID` sentinel when the user has selected **Default** — base
  styling, no profile appended — which is deliberately distinct from _unset_, so a migrated legacy
  profile stays active through the upgrade; and `BlurtCustomStyle`, the pre-profiles single field it
  still **reads and never
  writes** — an install with text there and no list reads back as one active profile named
  "Custom", so the migration is a read-side fallback with no launch hook to order. The active
  profile's instructions are appended to the cleanup instruction via
  `CleanupInstruction.sendable(appending:)`, re-read at every request; no profile, or blank
  instructions, sends the base instruction unchanged, and its `characterLimit` (4000 UTF-8 bytes)
  is the **per-profile** limit the editors and the engine's trim share — an editor bound, since
  `llm_instruction` is uncapped. Only the active profile is ever sent. One of the
  three stores with a setter, for the encoded-on-write reason below: the settings sheet and the
  main window's switcher write through it rather than binding the raw slots),
  **`MicDeviceStore`** (`BlurtMicDeviceUID`, the input device dictation is pinned to, as its
  CoreAudio UID — empty/unset follows the system default; re-read at every press, and a pinned
  device that isn't connected falls back to the system default without unpinning),
  **`OverlayOriginStore`** (the pill's dragged origin, x/y),
  **`MediaPauseStore`** (`BlurtPauseMediaWhileDictating`, experimental and off by default, the
  Advanced pane's Experimental section, independent of developer mode; gates pausing Spotify/Apple
  Music while recording, read on each edge into recording),
  **`TextShortcutStore`** (`BlurtTextShortcuts`, the JSON list of spoken phrase → saved text
  pairs; re-read per transcript via the session's `textShortcutsProvider` and applied locally by
  `TextShortcutExpander` between the response and the paste — never on the wire. Like
  `StyleProfileStore` it has a setter, because the value is encoded; the Settings window's Text
  Shortcuts pane writes through it).
- **`DefaultsKey`** (`Config/DefaultsKey.swift`) defines every key those stores write, one case each,
  and each store's `defaultsKey` reads its case from there rather than spelling a string literal.
  **`PersistedSettings.allDefaultsKeys`** is therefore just `DefaultsKey.allCases`, and
  **`PersistedSettings.resetAll(in:)`** is the sweep over it — the public door, which the UI-test
  launch reset calls. So adding a store and adding it to every "reset to a clean state" sweep aren't
  merely the same edit, they're the same line: there is no roster to keep in sync. (It used to be a
  hand-maintained array, and the forgotten half of that edit happened twice — the overlay origin and
  a since-removed update-check stamp.) A case's raw value is the _unprefixed_ half of the key: the key actually
  written is `HostIdentity.current.defaultsPrefix` + the raw value, which under Blurt's identity is
  the `Blurt…` names above and under a third-party host is that host's own namespace. Both halves are
  the on-disk contract: changing either abandons every existing user's setting, so rename cases freely
  and raw values never. The sweep lives next to the enum
  (not in the shell) so a reset needing more than a defaults removal has one place to grow and stays
  inside the test target; the roster itself is internal so no caller re-rolls its own sweep.
  `SigningIdentityMigration.lastSigningIdentityDefaultsKey` is deliberately **outside** the roster:
  it records what the TCC migration already did, not a user setting, and clearing it would make the
  next launch re-run the `tccutil` reset. (Its string value, `accessibility.lastSigningTeam`, is
  frozen — it predates both the ad-hoc case and the move to recording the designated requirement,
  and renaming it would re-run the reset for every installed user. The _value_ shape is not frozen:
  a shape change re-reads as one identity change per install, which is safe because a reset only
  runs when the app is already untrusted. See
  [the Accessibility grant](./AGENTS.md#the-accessibility-grant-and-signing-identity).)

Record cues: **`SoundPack`** is a selectable start/stop chime voice (vintage synth samples;
`id` doubles as the bundled stem `<id>-start.m4a` / `<id>-stop.m4a` under
`App/Blurt/Blurt/Resources/Sounds/`), and **`SoundPackCatalog`** is the set of them a host supplies —
picker sections, lookup, and the decode-with-default rule `SoundPackStore` and the `@AppStorage`
views share. The engine ships **no voices and no audio**: Blurt's 192 are generated into the app
target (`App/Blurt/Blurt/SoundPackCatalog.swift`) by `scripts/generate-sounds.swift` alongside the
`.m4a` files they name, because a voice list whose cues live in someone else's bundle is a picker in
which every choice plays silence. Regenerate both halves together — `check.sh`'s sound-catalog guard
exists because a drift plays silence with no error — and note that adding or removing a voice changes
the app target's file list, so `xcodegen generate` and a committed `.pbxproj` are part of that edit. **`RecordingCueGate`** decides
which chime fires on each recording edge — on the `.recording` edge, i.e. once audio is actually
flowing, never at the press (see the latency notes above for why that ordering is load-bearing); the
AppKit `CueSoundPlayer` just plays what it resolves.

**`RecordingEdgeDetector`** is the shared primitive underneath: a pure detector reporting `.began` on
the not-recording→recording transition and `.ended` on the reverse, silent everywhere else (the host
feeds it _every_ phase). `RecordingCueGate` is a thin mapping over it, and `MediaPauseGate` builds on it —
they want identical edges, so the edge logic exists once. Note `.ended` fires when the **mic closes**,
not at a terminal phase: anything suppressed for the microphone's benefit is restored as recording
stops, not a second later when the paste lands — unless the press goes on to speak or act, below.

Music: **`MediaPauseController`** (`App/Blurt/Blurt/`) pauses the user's music while the mic is open
and restores it after, so what they're listening to stays out of the transcript. Driven from
`AppCoordinator.render(_:)` like the chimes, and from `SelectionSpeechRouter.pressSettled`; its
decisions are the engine's **`MediaPauseGate`**. The resume comes from `pressSettled` once the mic has
closed: a dictation never takes the router out of rest, so its music returns in the render its mic
closes in; an ask's waits until the router is back at rest, so it never plays over the spoken answer,
and a rewrite's or composition's until it pastes. A **command's recording is not paused at all**
(`recordsCommand`): the command may be about the music, and the planner's play/pause key would toggle
the player Blurt paused back on. Experimental for now, so it can be trialled
before it is the default: off unless its own switch in the Advanced pane's Experimental section is on,
whatever developer mode says (trying it shouldn't mean logging every dictation to disk). Scoped to
**scriptable players** — `MediaPlayerApp` (Spotify, Apple Music). Both expose
`player state` through one shared script shape, so a dictation pauses only a player that is _already
playing_ and resumes only what it paused (tracked on the controller's serial queue, not against the
setting, so flipping the toggle off mid-dictation can't strand the music paused). `if application …
is running` is the idiom that reads the running state _without_ launching the app — a dictation must
never boot a music player. It cannot start anything unbidden. It
pauses rather than ducks the volume (an earlier ducking attempt, #171, was closed unmerged).

**Browsers are deliberately not covered — don't "fix" this.** Pausing safely needs to know something
is playing, and no public API answers that for a browser. All three routes were measured on macOS 26
and rejected: CoreAudio's device-level `kAudioDevicePropertyDeviceIsRunningSomewhere` reads busy with
the app quit and total silence; per-process `kAudioProcessPropertyIsRunningOutput` (public since
14.4) reports nothing for other processes without system-audio-recording consent, a far heavier
permission than the feature is worth; and MediaRemote (`MRMediaRemoteGetNowPlayingApplicationIsPlaying`)
is gated for unentitled apps, returning `false` while Spotify was demonstrably playing. A blind
system play/pause media key — the only thing that _reaches_ a browser — was built as an opt-in
fallback, tried in real use, and **removed**: with no state to read it toggles rather than pauses, so
it started playback that wasn't running. `MediaPlayerApp`'s doc carries the same warning next to the
code.

The scripts run in a short-lived **`/usr/bin/osascript` child process**, not in-process
`NSAppleScript` — a correctness requirement, not a style choice. In-process OSA leaked internally per
invocation (`scripts/leaks.sh` failed twice on backtraces through `executeAndReturnError`, and an
`autoreleasepool` did **not** help), and the leak only reproduced on CI. In a child the OSA
allocations die with `osascript`, so no Blurt frame can appear in a leak backtrace. TCC still
attributes the event to Blurt as the **responsible process**, so the prompt names Blurt and reads its
`NSAppleEventsUsageDescription`. Each player gets **its own script** (`MediaPlayerApp.pauseScript` / `resumeScript`): AppleScript resolves an
app's terminology at compile time, so one script naming both failed whole (-2741) on a Mac without
Spotify and Music never paused. The resume plays a player only if it is still paused, so playback
the user changed meanwhile is left alone — though a pause the user made themselves mid-dictation is
indistinguishable from Blurt's, so it is resumed too (a known limitation). Each `osascript` is
killed after 5 s, with both pipes drained concurrently; only a pause that _said_ it paused counts — one
that timed out may have found the player already paused by the user, and the still-paused check would
then start music they had stopped. The invocations sit on a **serial `DispatchQueue`**
so the restore always observes what the pause did, and the whole thing is fire-and-forget, so a
wedged player can never delay a recording. Quitting (a Sparkle relaunch included) always resumes on
`willTerminateNotification` — whether the gate still held the resume or it is already queued — killing
a pause still in flight first, then waiting at most 2 s (1 s a script); with nothing paused the queue
is idle and it returns at once. **A dictation never puts the consent prompt up**: before scripting, the
pause asks `AEDeterminePermissionToAutomateTarget` _without_ prompting (`AutomationConsent`), and
scripts only a `.granted` player — which also skips a player that isn't running, with no `NSWorkspace`
scan on the main actor. The prompt is asked only from Settings — as the switch turns on, or from the
"Allow…" button the Experimental section shows for a running player never asked — on a **queue of its
own**, since it blocks until the user answers and the dictation's pause and resume must not wait
behind it. The section re-reads consent on appear and whenever the app comes to the front, so its
"can't control" note survives a relaunch.
Reset clears the Automation grant with the others (`PermissionsReset.Service.appleEvents`,
`scripts/reset-lib.sh`). `MediaPlayerApp` (the roster, its scripts, and `AutomationConsent`) is its own file beside
`MediaPauseStore`. Sending
Apple Events needs **two** build-side pieces, both in `project.yml`: `NSAppleEventsUsageDescription`
(without it macOS _terminates_ the process on the first send instead of prompting) and the
`com.apple.security.automation.apple-events` entitlement (the hardened runtime otherwise blocks
outgoing events). A user who declines the consent prompt gets the note and an inert feature for that player.

`CueSoundPlayer` decodes and pre-rolls the players once so the first chime never stalls the pill, and
that pre-roll is bound to the output route it was made against. Blurt's own capture invalidates it:
opening the mic flips AirPods out of their output-only profile, dropping the output format underneath
the primed players. So the player observes **`AudioRouteMonitor.outputRouteChanges`** and reloads —
the monitor watches both the default output _device_ (a user switch) and the current device's nominal
sample rate (the profile flip), re-targeting the second listener whenever the first fires.

History: every dictation, read-aloud clip (its text and its audio, as a WAV the speaker writes as it plays — `ReadClip`), dropped or browsed-for file and Record-button recording is saved for good to
one list, **`TranscriptStore`** (`~/Library/Application Support/Blurt/history.json`; a debug build's is under `Blurt Dev/`, `HostIdentity.dataDirectoryName`, `SavedTranscript`
entries with their task results, and for a file or recording a short LLM-written title, `TranscriptLLM.title(for:)`) — what the main window's searchable, filterable Recent list shows. The app saves
each dictation the ring below gains, so one the session declined to remember (dictated into a secure
field) is never saved either; nothing in that store is ever sent as request context.
**`RecentDictations`** is an in-memory, newest-first ring (itself never written to disk) holding
`capacity` (100) dictations, of which the ready window lists `displayCapacity` (3). It is deep because
the history is also request context — `STTPrompt` sends it as the leading
lines of `stt_prompt` — so "how many do we remember" is a transcription-quality question, not a
layout one. **`DictationSession` owns the one ring**, since it assembles each request inside its
actor; the app's `AppCoordinator.recentDictations` is a projection pushed to it through
`onTranscriptDelivered` (which hands over the updated ring alongside the transcript), so the list can
never drift from the history that was actually sent, and nothing outside the session records into it.
**`DictationLog`** appends each completed dictation with its context snapshot to
`~/Library/Logs/Blurt/dictations.jsonl` (`DictationLog.defaultURL`, or `defaultDisplayPath` for the
home-abbreviated form to show in UI — derived next to the URL so the label can't drift from the write
target) — but **only** while developer mode is on; with it off, nothing is written. Every dictation
that ends in `.failed` is appended to a sibling `errors.jsonl` (`DictationLog+Errors.swift`:
`appendError` / `defaultErrorURL` / `defaultErrorDisplayPath`), behind the same switch — one line per
failure carrying `BlurtError.diagnosticName` (the stable label to aggregate on), the full description,
and the focused app/window/field, but deliberately **no** prior text, selected text, or prompt: the
surrounding text explains nothing about a failure and is the most sensitive part of the snapshot.
Errors go to their own file so the dictations log stays a corpus whose every line has a `transcript`.
The write is hooked in **`DictationSession.setPhase`**, not at the five `setPhase(.failed(…))` call
sites, so a failure path added later is logged by construction; `.noTarget` and `.cancelled` aren't
`.failed`, so the quiet "copied" notice stays out of the log. The one direct `appendError` call is
`stopAndCancel`'s failing `mic.stop()`: a cancel must not flash red, so that fault is logged **without**
a phase change rather than dropped. A failed append itself goes to `os_log` (never the entry, which
would leak transcripts system-wide) — it's the one error that can't be reported through the error log,
and it must never throw onto the dictation path. The Settings window's Advanced pane surfaces the
switch and both paths, and both the reset scripts (`scripts/reset-install.sh`, `scripts/reset-dev-install.sh`) and the in-app reset
(`DictationLog.removeStoredLogs()`, via `InstallReset`) remove all three files — plus the directory, once
it holds nothing else.

A third file, `commands.jsonl` (`DictationLog+Commands.swift`, same switch, queue and encoder), takes
each Control Your Mac command as it ended, with an `id`, so that it can be diagnosed — or turned into
an eval case — from the file alone: what was said; the app and window; how many elements were listed
and whether the read was cut short; **the exact user turn the model was sent** (the fenced element
list) and **every raw reply**, two when the plan was asked for again (`PlanTrace`); the model, a
version hash of the instruction and schema (`VoiceCommandPlanner.promptVersion`) and Blurt's build;
the plan one readable line per step (a numbered element with the kind and label it was listed
under); **what actually ran**, step by step — how each was carried out ("AXPress, then click: nothing
visibly changed", "AX focus; selected 18 characters", "key code 40"), how long it took, and the error
that stopped the rest (`StepRecord`, from `VoiceCommandPerforming.perform`'s note); the outcome; the
error's stable name and full text; and the total time. A failed command also goes to `errors.jsonl`
as `command.<name>`, so one file holds every failure. A command a press abandoned is logged with the
outcome `abandoned` and the steps that ran before it stopped, never as a failure — a request a cancel
reached first answers `URLError.cancelled`, which is treated as the cancellation it is — but only
when the job was cancelled (`Error.isAbandonment`): the same error on a job nobody cancelled is a
request the system dropped, and fails like any other. **Saying a complaint to the key** ("that last command didn't work", "that's wrong" —
`CommandFeedback`, short utterances only) isn't planned: it's logged as a feedback entry naming the
last command's id, and as `command.userReported` in `errors.jsonl`, and the pill says "Noted". The
reset sweep (`removeStoredLogs`, `scripts/reset-lib.sh`) removes all three files.

**Audio stays on whole 16-bit samples.** `relay` passes every captured chunk through `FrameAligner`
(`AssemblyAI/Dictation/FrameAligner.swift`) before the streamed body and the fallback's copy see it:
an odd chunk's last byte is carried into the next, and only a recording's final half sample is ever
dropped. The capture asks for 16-bit mono, but one chunk off the two-byte grid shifts every byte after
it, and the route refuses the body outright (`400 stream ended mid-frame with 1 trailing byte(s)`:
three Slack dictations lost on 2026-11-03). A misaligned capture is logged once, to name the device.

API key: stored in the macOS Keychain via **`APIKeyStore`**, a thin static facade over
**`MemoizedKeyStore`** (which takes its storage as `read`/`write` closures, so the memo-and-write rules
are unit-tested against a double instead of the real item). The injectable seam is **`APIKeyGateway`**
— `ProductionAPIKeyStore` forwards to the Keychain, `InMemoryAPIKeyStore` keeps automated runs away
from it. **`APIKeySubmission`** owns the validate-then-save flow (an unverified key never persists) and
its `Outcome.failureReport` classifies a failure as `.inline` (recoverable, shown beside the field) or
`.alert` (a Keychain fault retyping can't fix), so `APIKeyStepView` can't disagree with the engine
about severity. **`APIKeyModel`** (`@MainActor @Observable`) is the one shell-facing surface over
both, shared by the Mac app and the iPhone app: the observable `hasAPIKey` flag, `submit`/`save`,
and the `readinessCheck()` snapshot the session's press gate runs.
**`APIKeyDisplay.resolve(key:)`** owns how a stored key is _presented_ — masked tail,
status and VoiceOver wording, connect-vs-rotate control titles. The mask reveals only the last four
characters and, below `minimumLengthToMask`, none at all (a bare `suffix(4)` in the view once rendered
a short key whole).

Sign in with AssemblyAI: the other way to fill that same key item. **`AssemblyAIAccount`**
(`@MainActor @Observable`, in `Sources/BlurtAssemblyAI/Account/`) runs the authorization-code + PKCE flow
against a public Connected App: the shell's `AccountSignIn` opens the consent page in an
`ASWebAuthenticationSession` (redirect `com.assemblyai.blurt://oauth/callback`, caught by the session, so no URL
handler is registered), and the engine trades the code for tokens and the access token for the
connection's API key (`POST /api/v2/oauth/api-key`), which it saves through `APIKeyModel` like a
pasted key — the transcriber, the press gate and the TTS clients can't tell the two apart. Beside it,
a second Keychain item (`AssemblyAISignIn`, `SignInStore`) holds the **`SignInSession`**: refresh
token, email, key expiry and last renewal. Its read keeps "none" apart from "unavailable" (a locked
Keychain), for the reason `MemoizedKeyStore` gives: an unreadable item must not read as signed out,
or Sign Out would delete the key without ending the connection. `runRenewal()` (started once at launch) sleeps until the renewal is due — when the exchange said the
key rotates (`api_key_rotates_at`: AMS mints the next key and disables the old one once an exchange
lands inside its window, two days before expiry), else two days before expiry (`SignInSession.renewalDue`;
at most a day per sleep, on the continuous clock so a renewal that fell due while the Mac slept runs on
wake) — then refreshes and re-exchanges: one renewal per key, since the
refresh token's three-month sliding lifetime dwarfs a key's two weeks. `KeyRejectionReporter` wraps the
transcriber and calls `keyWasRejected()` when dictation refuses the key (401, or the API's invalid-key
404), which renews at once (at most every 15 minutes) so the next dictation has a working key; the
refused utterance itself can't be retried, its audio having streamed as it was spoken. A renewal that brings back the same key with its renewal already due (a server that didn't rotate
early) defers the next one to the key's expiry, or a day out once it has expired, instead of asking
every minute. Renewal keeps a rotated refresh token before anything else can fail; a refused refresh
or exchange means the connection was ended elsewhere and drops key and session, an unreachable server
changes nothing. "Refused" at the token endpoint means an `invalid_grant` or `invalid_client` error,
not any 400: an `invalid_request` mid-deploy or a proxy's page says nothing about the grant. A
renewed key the Keychain won't take leaves the session's dates alone, so the renewal stays due. A
renewal suspends twice on the network, so a `generation` counter makes one that
wakes after a sign-out, reset or new sign-in write nothing; `signOut()` waits out a renewal in
flight first, starts none while it talks to the server, and keeps a sign-in that lands meanwhile. A
sign-in whose key the Keychain refuses puts the earlier session back and revokes the grant it just
minted. A sign-in over a session item that can't be read replaces it, since refusing would fail every
sign-in for as long as it stays unreadable; a key refused then rolls back to no session. An
unreadable session item (a locked Keychain) is looked at again every five minutes, and the
loop re-reads the status each pass. `signOut()` ends the connection server-side (`POST /api/v2/oauth/api-key/revoke`) and
only then forgets it here; a revoke the server couldn't confirm (503) leaves everything in place and
returns an inline report so the user can retry (`SignInFailure.failureReport` makes the same
inline-vs-alert split as `APIKeySubmission`). `CredentialRows.resolve` decides which of the account
and key rows show and which button is filled. Pasting a key is a first-class alternative, not a legacy
path — keep it: a team rolling Blurt out shares one key rather than adding every member, engineer or
not, to its AssemblyAI account. Until either is set up they are one choice (`.choice`): a single
"Connect to AssemblyAI" row with Use API Key… beside the filled Sign In…. Connected, only the way in use
shows — a pasted key's row alone (a Sign In… beside it read as a step still to do), or the signed-in
account row, the key then being the connection's to rotate. `InstallReset` clears the session item with the key.
The wire half (`OAuthAuthorization`, `OAuthClient`) is in the `AssemblyAI` library. The build turns
sign-in on with four Info.plist values (`BLURT_OAUTH_*`, read by `OAuthConfiguration.blurt`):
production's, committed in `App/Blurt/Config/SignIn.release.xcconfig`, for every configuration —
dev builds too, through `SignIn.xcconfig`, which then includes the gitignored
`SignIn.local.xcconfig`: a developer's override pointing a dev build at a sandbox deployment, whose
values aren't committed. Any one empty hides sign-in, and a session inherited by a build without
it can still be signed out (locally). A signed-in key also
dictates against the host its sign-in configures (`BLURT_OAUTH_DICTATION_ORIGIN`, optional; a sandbox
key only works against its sandbox's host): the account keeps a `DictationOrigin` current as it signs
in and out, and the app's `baseURL` closure for `AssemblyAITranscriber` reads it at every request and
warm-up. A pasted key, or no
origin configured, dictates against production.

Setup gating: **`SetupReadiness.isReady(permissions:hasAPIKey:)`** is the fully-configured rule
(deliberately excluding the trigger key, which has a default binding, so a shortcut change can't trap
the user in the wizard), `SetupReadiness.pollInterval(isReady:)` the permission-poll cadence (brisk
during setup, coasting once ready), and `PermissionStatus.lostGrant(since:)` the revocation edge that
pulls a configured app back into onboarding. `WizardController` applies all three rather than
restating them.

## App shell surfaces

`App/Blurt/Blurt/BlurtApp.swift` declares four scenes (five in Debug):

- **Main window** (`MainWindowRoot`) — the setup wizard until the app is fully configured, then the
  "ready" screen (`ReadyView`), shaped like a dictation app's home: Blurt's work happens outside the
  window, on the keys, so they lead — a legend under a Keys heading on a soft translucent panel (not a white card:
  only Library entries are cards) with each configured key's action and the key as a keycap (`KeyCap`) by its
  full name ("Right Command", the name every Settings row uses), so it reads as a key to press, not a
  control — not clickable, and nothing in the window reacts while a key is down (how a dictation is going is the pill's to say); once a custom style
  exists, a Style row's pop-up (Default plus up to 4 profiles, ⌘1–⌘5) closes
  the card, with a footer only while enhanced transcripts are off. Below it, the Library as a feed of
  what Blurt has done. The whole window scrolls as one list, as Journal's (the keys lead it and scroll
  away, the scroller is the window's), on a pale wash of the brand green (`BlurtBrand.backdrop`) with no rule
  under the toolbar; the entries are white cards (`LibraryCard`). The Library is a stock `List` drawn as cards (row
  backgrounds and insets; the table's own highlight turned off so a selected card takes a Journal-style
  accent ring): a click selects, double-click or Return opens, ⌘C copies, Delete deletes, arrows move;
  day headings are ordinary rows, so they scroll rather than pin. Entries are compact cards with the time on the details line and a ⋯ menu
  of the entry's actions (Open, Play, Copy, Show in Finder, Delete…), and when empty a
  first-dictation prompt. The unified toolbar holds Record and
  Browse leading, then the Library's Filter menu (Mail's: one kind or all, the icon filled while a
  filter is on), Settings, and the search (`.searchable`, ⌘F: its own capsule at the trailing edge,
  widening when clicked into, as Finder's and Mail's do) with no title beside it. Esc cancels a dictation while the window
  is key. Opening an item — and a recording, or a file going up — slides the window over to it, as an
  entry does in Journal (`TranscriptPage`): a back button leads the toolbar on its own, the item's
  title heads the page (in the toolbar it crowded the actions into a » menu), and its actions
  follow as icons — the View menu (✨: the transcript, Plain text, the stock tasks,
  Custom…), Play and Stop — the entry's own audio, or speech generated on the spot (a spinner until
  the first word), Copy, Show in Finder, Delete — over the transcript. Nothing there is edited, so
  there's no Done or check mark: back (or Esc) slides back to the Library, abandoning a file going up;
  a recording holds the page until it's stopped or discarded. A file comes in four ways, as
  a Mac app's do: dropped anywhere on the window (`audioFileDropTarget` — no drop zone at rest, an
  accent overlay saying "Drop to Transcribe" only while a file is held over it), dropped on the Dock
  icon or opened from Finder's Open With (`CFBundleDocumentTypes`, an Alternate handler for
  `public.audiovisual-content`, through `AppDelegate.application(_:open:)`), File › Open… (⌘O), or
  Browse; each goes through `TranscriptsModel.openFiles`, which refuses anything but audio or video
  with a reason. No footer: Report a bug and the LinkedIn share are in the Help menu. Always presented
  at launch.
- **Settings** (`SettingsWindowRoot`) — a `TabView` reached via ⌘, / the menu bar,
  never at launch. General holds the everyday setup (account, mic, meeting auto-record); Keys holds an action-per-row table with one activation mode; Sounds holds each key's cue voice; Styles leads with the
  enhanced-transcripts switch (styles only shape that rewrite) above the style profiles; Vocabulary
  holds the key terms and the text-shortcut table (+ / −, double-click to edit); Advanced holds
  the update check, the developer-mode toggle, and the **reset** — one destructive button running the engine's `InstallReset` (the same sweep as
  `scripts/reset-install.sh` / `scripts/reset-dev-install.sh`: settings, Keychain key, TCC grants, dictation logs), which confirms
  first and then **restarts the app** (a detached `sh -c 'sleep 1; open -n <bundle>'`, since whatever
  reopens Blurt has to outlive it). The restart is load-bearing, not a courtesy: macOS prompts for a
  TCC grant once per process, so only a process started after the sweep gets the prompts back — and
  the fresh one, having no key and no grants, opens on the setup wizard by the same
  `SetupReadiness` gate as a first run. A _partial_ reset skips the restart and reports what
  survived instead. Note macOS titles a preference window
  after its selected pane, which is why the UI-test suite aliases the window title to the first
  tab's label.
- **`MenuBarExtra`** (`MenuBar/`) — live dictation indicator plus a
  discoverability menu for the otherwise-invisible hotkey. Convenience layered on the Dock icon.
- **Overlay** (`Overlay/OverlayWindowController` + `OverlayView`) — the floating pill: meter, phase
  label, notices. Geometry and phase mapping come from the engine (`OverlayPlacement`,
  `MeterBarGeometry`, `OverlayUIState`); Reduce Motion is honored.
- **UI-test harness window** — `#if UITEST_HOOKS` only; see [Tests](./AGENTS.md#tests).

## Updates

Blurt updates itself with [Sparkle](https://sparkle-project.org) 2 — the Mac app's one remote
package, pinned exactly in `project.yml` and `Package.resolved`. Sparkle owns the whole flow: the scheduled
background check (daily), the "up to date" / "new version available" UI, downloading the DMG,
verifying its EdDSA signature, and replacing the app in place. Nothing about updates lives in the
engine any more; the download-only GitHub-API checker (`UpdateChecker`, `UpdateAlertContent`,
`AutomaticUpdateCheck`, `LastUpdateCheckStore`, `SemanticVersion`) was removed with the switch.

- **`UpdaterModel`** (`App/Blurt/Blurt/Update/UpdaterModel.swift`, `@MainActor @Observable`) wraps
  one `SPUStandardUpdaterController`. `AppDelegate` owns the single instance; the app-menu "Check for
  Updates…" command, the menu-bar item, and the Settings → Advanced → Updates section all drive it.
  It mirrors `canCheckForUpdates` (KVO) so every entry point disables itself while a check runs, and
  exposes Sparkle's two preferences — check automatically (on by default) and download-and-install
  automatically (off by default) — as Settings toggles.
- **Only the shipping bundle id starts the updater** (`dev.alex.blurt`, i.e. `HostIdentity.blurt.subsystem`,
  decided the same way `BlurtApp.init` picks the host identity). "Blurt Dev" and the UI-test build are
  separate apps, and the appcast describes the release, so a running updater there would offer to
  overwrite a dev build with a shipped one. Unstarted, `canCheckForUpdates` stays false: the controls
  render disabled and the Updates footer says development builds don't update.
- **Configuration is `Info.plist`, from `project.yml`**: `SUFeedURL` is
  `https://github.com/AssemblyAI/blurt/releases/latest/download/appcast.xml` (a stable release-asset
  URL, so no Pages site or extra hosting); `SUPublicEDKey` comes from the `SPARKLE_PUBLIC_ED_KEY`
  build setting; `SUEnableAutomaticChecks` is set, which also skips Sparkle's second-launch "check
  automatically?" prompt. Sparkle never checks on an app's very first launch, so a first run is not
  greeted by an update dialog over its setup screen.
- **The release pipeline produces the feed.** `release-build.sh` signs the notarized DMG with the
  EdDSA private key (`SPARKLE_ED_PRIVATE_KEY`, a `release-build` secret) using Sparkle's
  `sign_update`, and writes a one-item `appcast.xml` whose enclosure is the versioned DMG on the
  release. `release-publish.sh` attaches it to the release, verifies the re-download, and only then
  flips the release live — which is the moment `/latest/download/appcast.xml` starts pointing at it.
  Sparkle compares `CFBundleVersion` (`sparkle:version`), which `release-bump.sh` increments on every
  bump. See [`RELEASE.md`](./RELEASE.md#sparkle-updates).
