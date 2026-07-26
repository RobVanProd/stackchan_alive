# Bridge Work Handoff

Instructions for the agent working on the host bridge and brain. Self-contained: you should be
able to act on this without the conversation that produced it.

The goal is a Stackchan that holds a back-and-forth conversation, speaks when it has a reason to,
knows something about the room it is in, and notices people.

Read [AGENTS.md](../AGENTS.md) first, then [BRIDGE_PROTOCOL.md](BRIDGE_PROTOCOL.md),
[CHARACTER_LOCK.md](CHARACTER_LOCK.md), and [CONVERSATION_V2_ROADMAP.md](CONVERSATION_V2_ROADMAP.md).
This document is the work list; those are the contracts.

## Division Of Labour

Firmware owns reflexes, safety, actuator authority, wake, and the display gate. The bridge owns
STT, the model, memory, TTS, and conversation pacing and initiative. **The model never gets
actuator, power, pairing, or OTA authority**, and nothing below changes that.

Most of what follows needs **no firmware change**. Where firmware work is genuinely required it is
called out.

This bridge candidate does not modify firmware. The working image from `main` is an immutable
qualification dependency; firmware findings are reported to its owner instead of being patched in
this branch.

## How To Read The Robot's State

Everything in this document was diagnosed from the robot itself. Use the same sources.

```bash
# Full JSON snapshot: compiled flags, bridge, camera, power, OTA, sensors
curl -s http://<robot-ip>:8789/debug | python3 -m json.tool

# Serial telemetry, plus a status dump on demand
printf 'status\n' > /dev/ttyACM1
```

Useful serial commands: `status`, `demo off`, `motion off`, `motion on`.

The `[face]` line prints every 5 s and includes `mode=`, which is the single most useful number
when behaviour looks wrong. `CharacterMode` values are `0 Boot, 1 Idle, 2 Attend, 3 Listen,
4 Think, 5 Speak, 6 React, 7 Sleep, 8 Error`.

## Source Implementation Update (2026-07-24)

- Conversation v2 now emits a constant 10-second reply lease and allows 24 user turns by default.
  Completed turns no longer make the listener progressively less patient. The unchanged main
  firmware rejects out-of-range values rather than silently clamping them. The feature remains
  explicit and still needs exact-image hardware qualification before promotion.
- `bridge/initiative_policy.py` implements the ten-minute hard floor, fresh-person requirement,
  circadian suppression, busy/safety gates, curiosity decay, and two-ignored-opener backoff.
  Initiative generation uses the normal Character Lock and TTS path but never opens a microphone
  or motion lease.
- `bridge/room_context.py` implements low-rate in-memory capture, typed privacy filtering, scene
  diffs, prompt-safe ambient context, and clean degradation. `bridge/ollama_room_vision.py`
  converts PGM to PNG in memory and permits only a loopback Ollama vision endpoint.
- The loopback dashboard exposes initiative and room-observation switches plus a bounded
  2-30 minute interval. Raw frames and free-form model descriptions never enter dashboard state.
- Production startup now uses a resident loopback whisper.cpp server. A real robot utterance
  measured about 0.51-0.59 seconds in-process, and normal startup uses redacted turn logs with no
  microphone WAV persistence.
- The pinned loopback-only SearXNG service now passes live JSON search, engine allowlist, broker
  search, restricted HTTPS fetch, and audit gates. The bridge routes explicit searches and
  ordinary freshness-sensitive questions through one bounded research round; fetched text cannot
  write memory or gain robot authority. Natural routing, citations, caching, observability, and
  mixed voice/research latency remain tracked refinements in
  [LOCAL_RESEARCH_TOOLING.md](LOCAL_RESEARCH_TOOLING.md).
- The host freezes PCM on the socket thread at `utterance_end`, verifies declared byte/chunk
  totals, and records late binary frames as protocol failures. Phrase streaming no longer applies
  the final 250 ms drain pause between intermediate phrases.
- `bridge/bridge_ai_qualification.py` and the passive start/complete wrappers enforce the exact
  physical gates in [BRIDGE_AI_QUALIFICATION.md](BRIDGE_AI_QUALIFICATION.md).
- All new behavior is default-off at the command line. Use the explicit launch switches during
  supervised qualification; do not infer hardware readiness from source tests.

## Fault-Fix Candidate Update (2026-07-25)

- F1 has a source-level wire guard. Once `response_start` is sent, cancellation and worker-error
  paths discard buffered audio, send a nonfatal `response_aborted`, and send the matching
  `response_end`. Overlap, sequence mismatch, and unrecovered closure events are privacy-safe
  qualification failures.
- F2 is a firmware-owned capture finding, not a bridge source change. The bridge freezes each
  utterance on the socket thread, rejects late binary frames, verifies declared totals, and keeps
  privacy-safe counters. Qualification still requires zero robot uplink-error delta; any nonzero
  result is handed to the firmware owner with the exact main image hash and telemetry.
- F3 is localized to production startup never launching `bridge/vision_service.py`. The DirectML
  launcher now starts the pairing-file-only YuNet worker whenever face vision is requested or
  room observation is enabled, then requires authenticated frame and target counters to advance.
  The dashboard reports Waiting for host, Scanning, or Tracking instead of treating camera power
  as proof of host vision.
- F4 is localized to the current phrase-streaming cadence. The accepted 70 ms wire benchmark
  predates per-chunk mouth frames; applying the general 40 ms text delay to every mouth frame left
  only 18 ms of a 128 ms PCM chunk for scheduler and network jitter. Mouth frames no longer consume
  that pacing budget, leaving 58 ms of nominal headroom, and qualification now rejects fewer than
  25 ms.

Silence or an explicit no-transcript STT result is also a normal turn outcome now. An initial
capture with no transcript speaks one short retry through the Character Lock and TTS path. A
follow-up capture that fails the firmware-matched PCM speech gate closes silently before STT,
preventing room noise from creating a hallucinated turn. Neither path writes conversation history
or opens another reply window.

These are source-tested candidates, not physical closure. F1-F4 remain open until one exact clean
bridge source commit passes the supervised qualification and soak against the unchanged accepted
main firmware binary described below.

---

# Part 1: Open faults on the host side

These are confirmed from the reference robot's own telemetry. They are host-side, not firmware, and
they block work described later in this document. Fix these first.

## F1. Replies are started and never closed

**Observed:** the robot sat at `mode=5` (Speak) for 152 consecutive telemetry samples with
`speech_active=0`, `bridge_downlink_playback_starts: 0`, and `speaker_running: false`. It was not
speaking at all. A `response_start` frame arrived and no `response_end` ever followed. The socket
stayed healthy the whole time (`bridge_state: ready`).

**Impact:** the firmware's character mode is driven by these frames. A missing `response_end`
stranded the robot in a speaking state indefinitely. Firmware now force-recovers to Idle after
90 s, but that is a backstop, not a fix. Until this is corrected, every dropped end frame costs a
90 second stall and any conversation feels like it trails off.

**What to check:** that every `response_start` is followed by `response_end` on every exit path,
including model errors, TTS failures, cancellation, barge-in, and owner loss. The response
sequence is documented in [BRIDGE_PROTOCOL.md](BRIDGE_PROTOCOL.md); the ordered form is
`response_start` → `audio_stream_start` → binary chunks → `audio_stream_end` → `audio` → `response_end`.
`playback_starts: 0` on a response that supposedly began suggests the failure happens before or
during TTS, so the error path is the likely culprit.

**Candidate fix:** implemented and socket-tested on 2026-07-25. Re-run cancellation, model/TTS
failure, owner-loss, and long-running physical conversation cases; the qualification must report
`host-response-wire-clean` with no unrecovered events.

## F2. Roughly 16 uplink errors per turn

**Observed:** `bridge_uplink_errors: 80` across `bridge_uplink_turns: 5`, while
`bridge_uplink_completed: 5`, `bridge_uplink_aborted: 0`, `bridge_uplink_gate_blocks: 0`,
`bridge_uplink_queue_failures: 0`, and `audio_capture_drops: 0`.

Every turn completed, so this is not breaking conversations. But the counter scales with turns, and
by elimination against `src/io/BridgeAudioUplink.cpp` the likely path is `audio_uplink_not_active`:
microphone chunks still being pushed after `utterance_end`, each one rejected and counted.

**What to check:** stop pushing PCM once `utterance_end` has been sent, or close the capture
window before the tail chunks arrive. Low severity, but it makes the counter useless as a health
signal, which matters once you are relying on telemetry to tune conversation pacing.

**Bridge-side status:** late audio is rejected and counted after the immutable utterance snapshot.
The supervised run must show zero `bridge_uplink_errors` delta across completed turns; do not reset
the counter to manufacture that result. A nonzero robot counter remains a firmware-owner finding.

## F3. Vision delivers nothing at all

**Observed:** `camera_frames` climbing normally, but `camera_face_batches: 0`,
`camera_faces_observed: 0`, `camera_target_valid: false`, `camera_events: 0`. The camera works and
the robot is serving frames; the host has never returned a single detection.

**Impact, and this is bigger than face tracking:**

- Face-follow motion has no input.
- Active-speaker selection has no input.
- The natural `Attend` → `Idle` path in firmware is driven by a `FaceLost` event, which never
  fires. Firmware now decays attention on a timer instead, but presence-driven behaviour is the
  correct mechanism and it is dead.
- Everything in Part 3 below (curiosity, noticing arrival and departure) has no signal to work
  from.

**What to check:** `bridge/vision_service.py` polls the robot's authenticated camera endpoint,
parses the returned PGM, runs YuNet, and posts face targets back. Confirm it is running, that
pairing succeeds, and that it can reach the camera endpoint. Note the frames are **grayscale PGM**,
which is fine for detection but means no colour reasoning.

**Candidate fix:** implemented and launcher-tested on 2026-07-25. Production startup now owns the
vision worker and refuses a vision-enabled ready result until both authenticated frame requests and
target updates advance with no new frame/auth failures. Physical qualification additionally
requires advancing face batches, observed faces, and camera events.

## F4. Speech is subtly choppy

**Observed:** the operator heard slight choppiness while the bridge used 4096-byte, 16 kHz PCM
chunks with 70 ms binary pacing and 40 ms text pacing.

The earlier passing wire benchmark emitted no per-chunk mouth frames. Current speech emits one
mouth frame before every PCM chunk, so the two sleeps became additive: 110 ms of configured cadence
inside a 128 ms chunk. That byte-perfect stream can still starve under ordinary Windows and Wi-Fi
jitter.

**Candidate fix:** streaming mouth frames bypass the general text delay while ordinary bridge text
frames retain it. Every completed streaming turn records chunk duration, configured cadence,
headroom, and a 25 ms minimum-headroom result. Supervised qualification requires three or more
streaming turns and rejects any unsafe result; the operator must still confirm continuous audio
with no phrase-boundary gap or clipped tail.

---

# Part 2: Conversation without a wake word every turn

**Status: mostly built. Turn it on and qualify it; do not rewrite it.**

Already implemented and tested:

- `bridge/conversation_session.py` — deterministic session lease, reply window, exit phrase,
  silence timeout, turn limit, bridge-loss cleanup, barge-in cancellation.
- `bridge/test_conversation_session.py` — transition coverage.
- `bridge/lan_service.py` — `--conversation-v2`, `--conversation-reply-window-ms`,
  `--conversation-acoustic-tail-ms`, `--conversation-cooldown-ms`, `--conversation-max-turns`.
- Firmware — `conversation_reply_window` frame, `src/io/ConversationReplyWindow.cpp`, and a local
  voice-activity endpoint in `src/io/VoiceActivityEndpoint.cpp`.

The shape is: one onboard wake word opens a session; after that each reply reopens the microphone
automatically; the session ends on silence, an exit phrase, a turn limit, or bridge loss.

## What to do

1. Run with `--conversation-v2` and confirm a full multi-turn exchange from a single wake word.
2. **Reopen only after confirmed playback drain.** The robot sends `playback_complete` per response
   sequence; use that plus the measured acoustic tail. Do not estimate speech duration from word
   count — the telemetry already exists and the roadmap is explicit about this.
3. `open_after_ms` is clamped 0–2000 and `window_ms` 1000–30000. Out-of-range values are rejected
   by firmware, not silently corrected.
4. At most **one** pending follow-up. A transcript arriving during `THINKING` or `SPEAKING` is
   either an explicit barge-in cancel or a rejected busy event — never hidden backlog.
5. Echo guard while the speaker is live, or he will answer himself.
6. Fix F1 first. A conversation that cannot reliably close a turn cannot reliably chain turns.

## Tuning the "conversation is over" feel

Do not shorten the listening lease merely because several turns completed. That made Stackchan
progressively less patient during an active exchange. The host default is now a constant ten
seconds and a 24-turn safety bound.

The accepted firmware image has a separate microphone endpoint: 550 ms of trailing silence and a
4.8-second maximum reply capture. Live telemetry on 2026-07-26 showed 199 reply captures, zero
reply-window expirations, and 119 maximum-duration fallbacks. That proves the observed mid-thought
cutoff is device endpointing, not expiration of the bridge lease. Any change to those endpoint
values belongs in a separate firmware PR and must preserve wake gating, echo rejection, uplink
accounting, and the accepted image's qualification evidence.

---

# Part 3: Speaking on his own, and curiosity

## Unprompted speech needs no firmware change

Firmware does **not** gate `response_start` on a preceding user turn
(`src/io/BridgeClient.cpp:135`). It transitions to `Responding` and renders whatever it is given.
So the bridge can speak at any moment by sending the ordinary response sequence. Mouth sync, RGB,
gesture, and the `intent` mapping all work already.

What is missing is an **initiative policy** on the host deciding when it is worth speaking. This is
the part that makes it charming or unbearable, so treat the rate limit as the feature:

- A hard floor between unprompted utterances. Start at 10+ minutes and tune down carefully.
- Never interrupt an active session, `THINKING`, `SPEAKING`, or a safety state.
- **Never speak while he is asleep.** See Part 4 — `mode=7` and the sleep telemetry tell you.
- Never speak into an empty room. Require a present person, which needs F3 fixed.
- Suppress at night using the persona's circadian hours (`personas/<id>/behavior.yaml`).
- Back off hard on non-response. Two unprompted openers in a row with no reply should buy a long
  silence. A robot that keeps talking at someone ignoring it reads needy, not curious.
- Route it through the same Character Lock validation as any other response. Unprompted speech is
  not exempt from the persona schema.

A good unprompted line is short, specific, and easy to ignore. "Did the lamp move?" beats "Hello!
I noticed something! Would you like to talk about it?"

## Curiosity should follow change, not presence

Firmware now models habituation per event type (`src/persona/EmotionModel.cpp`): the same stimulus
stops registering as news when it repeats, and recovers when it stops. Mirror that host-side.

**The thing worth remarking on is the thing that changed.** A person at the desk for an hour is not
news. A person who just arrived, or who left and came back, is.

1. Track presence *transitions*, not presence: arrival, departure, return-after-absence, new face
   versus familiar face.
2. Let a transition raise a curiosity score that decays. Only cross into speech when it clears a
   threshold **and** the rate limit above allows it.
3. Prefer asking to announcing. "You are back early" invites a reply; "A person has been detected"
   does not.
4. Keep the memory rules. Bounded session context may live in memory, but raw transcripts are never
   durable. Only schema-validated, privacy-filtered facts survive session close. "Rob usually
   arrives around nine" is a fact; a transcript is not.

This all depends on F3.

---

# Part 4: Firmware state you can now use

Recent firmware work added character state that is useful to you, and one state you must respect.

## He now sleeps, and you must not talk over it

Left alone, he gets progressively drowsy and falls asleep after roughly 8.5 minutes, then wakes on
touch, wake word, pickup, shake, tilt, loud noise, a detected face, or a fault. Confirmed on
hardware: 98 consecutive Idle samples followed by 42 at `mode=7`.

The ladder is visible before he goes: heavy lids from fatigue 0.45, yawns at 0.62, asleep at 0.80.

For the bridge:

- **`mode=7` means asleep.** Do not send unprompted speech. Do not open a reply window.
- If you want to wake him deliberately, send a rousing event; his own bookkeeping
  (`response_end`, `thinking`) deliberately does not wake him.
- A conversation started while he is asleep should wake him first and let the wake settle, not
  talk at a closed-eyed robot.

## Signals worth putting in the prompt

The `heartbeat` frame carries bounded embodiment facts. Consider exposing to the character prompt:

- fatigue / sleep pressure — "he is sleepy" is legitimate character context
- mood: arousal, valence, focus
- the drifting temperament baseline, which now moves slowly with accumulated experience
- battery and charge state, already shaped into `EmbodiedEnergy`

Do not let the model act on these as commands; they are context.

## Demo mode is on by default and will confuse you

`IntentEngine::demoEnabled_` defaults to **true** and injects a random mode change plus a fake
event every 2.5–6 seconds. While it is on, the robot's mode flips constantly for no reason, the
body light follows, and he can never fall asleep.

**Send `demo off` before drawing any conclusion about behaviour.** A large amount of apparently
random character behaviour turned out to be this.

---

# Part 5: Letting the model see the room

**Status: the frame path exists, the model has never been given an image.** Blocked on F3.

`bridge/vision_service.py` already polls the authenticated camera endpoint and runs YuNet. Frames
are **grayscale PGM** — adequate for coarse scene description, useless for colour reasoning.

1. Make it a **periodic, low-rate** room observation. Every few minutes, not every frame. This is
   ambient context, not a video feed, and every capture costs privacy and latency.
2. Feed the frame to the vision-capable model and keep a short structured scene summary — a couple
   of sentences, or better a small set of typed fields. Put that in the prompt as ambient context
   so answers can reference the room without a tool call.
3. **Diff successive summaries.** The change between them is the curiosity signal for Part 3, and
   far more useful than the raw description.
4. **Privacy is a hard constraint.** Per [PRIVACY.md](PRIVACY.md) and AGENTS.md: never persist raw
   frames, never commit them, keep the summary privacy-filtered like any other memory. A stored
   description of a person in their home is memory and follows the same rules. Make the capture
   interval and an off switch user-visible.
5. Degrade cleanly. No camera, no pairing, or no vision model must leave conversation fully
   working, the same way bridge loss leaves the local face and wake behaviour intact.

---

# Constraints that are not negotiable

From [AGENTS.md](../AGENTS.md), repeated because everything above brushes against them:

- Audio stays wake-gated at session entry. Conversation v2 reopens the microphone *inside* an
  established session; it does not make the robot always-listening.
- A conversation lease never grants or refreshes actuator motion.
- Do not weaken wake-gating, memory privacy, pairing, OTA health, power, thermal, motion session,
  camera-auth, or display gates to make any of this pass.
- One host brain owner, one generation at a time. Owner loss cancels the in-flight turn.
- Bridge or host loss returns firmware to its normal local face, wake, and packaged-prompt
  behaviour.

# Verification

```bash
python -m unittest discover -s bridge -p "test_*.py"      # from the repo root
python bridge/trusted_facts_smoke.py --memory-file output/pc-brain/latest/memory.json --json
python bridge/character_red_team.py --json
```

The trusted-facts smoke must stay silent (`modelInvocations: 0`, `audioPlayed: false`). New
behaviour needs new tests in the same style: deterministic, no hardware, no network.

For anything that reaches the robot, follow the existing evidence discipline: native tests, then
embedded build, then a short supervised run, then longer soak. Do not transfer evidence between
firmware SHAs.

One lesson from the firmware side worth carrying over: **simulation from a clean start proves very
little about a long-running robot.** The sleep behaviour passed every simulated test twice while
failing on hardware, because the real robot was sitting in states a fresh run never reaches. When
you think a conversation feature works, check `mode=` on a robot that has been up for hours.
