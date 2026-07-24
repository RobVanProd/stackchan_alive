# Bridge Work Handoff

Instructions for the agent working on the host bridge and brain. The goal is a Stackchan that
holds a back-and-forth conversation, speaks when it has a reason to, and knows something about
the room it is sitting in.

Read [AGENTS.md](../AGENTS.md) first, then [BRIDGE_PROTOCOL.md](BRIDGE_PROTOCOL.md),
[CHARACTER_LOCK.md](CHARACTER_LOCK.md), and [CONVERSATION_V2_ROADMAP.md](CONVERSATION_V2_ROADMAP.md).
This document is the work list; those are the contracts.

## Division Of Labour

Firmware owns reflexes, safety, actuator authority, wake, and the display gate. The bridge owns
STT, the model, memory, TTS, and now conversation pacing and initiative. **The model never gets
actuator, power, pairing, or OTA authority**, and nothing below changes that.

Four of the five items here need **no firmware change at all**. Where firmware work is genuinely
required it is called out explicitly.

---

## A. Conversation without a wake word every turn

**Status: mostly built. Your job is to turn it on and qualify it, not to write it.**

Already implemented and tested:

- `bridge/conversation_session.py` — the deterministic session lease, reply window, exit phrase,
  silence timeout, turn limit, bridge-loss cleanup, and barge-in cancellation.
- `bridge/test_conversation_session.py` — transition coverage.
- `bridge/lan_service.py` — `--conversation-v2`, `--conversation-reply-window-ms`,
  `--conversation-acoustic-tail-ms`, `--conversation-cooldown-ms`, `--conversation-max-turns`.
- Firmware — `conversation_reply_window` frame, `src/io/ConversationReplyWindow.cpp`, and a local
  voice-activity endpoint in `src/io/VoiceActivityEndpoint.cpp`.

The shape is: one onboard wake word opens a session. After that, each reply reopens the mic
automatically, and the session ends on silence, an exit phrase, a turn limit, or bridge loss.

### What to do

1. Run the bridge with `--conversation-v2` and confirm a full multi-turn exchange from one wake.
2. **Reopen only after confirmed playback drain.** The robot sends `playback_complete` for each
   response sequence. Use that plus the measured acoustic tail. Do not estimate speech duration
   from word count — the roadmap is explicit about this and the telemetry already exists.
3. `open_after_ms` is clamped 0–2000 and `window_ms` 1000–30000. Values outside those are rejected
   by firmware, not silently corrected.
4. At most **one** pending follow-up. A transcript arriving during `THINKING` or `SPEAKING` is
   either an explicit barge-in cancel or a rejected busy event — never a hidden backlog.
5. Echo guard while the speaker is live, or the robot will answer itself.

### Tuning the "conversation is over" feel

The silence timeout is the whole feel of the ending. Too short and it hangs up on a person who is
thinking; too long and it stares at an empty room. Start around 6–8 s of trailing silence for the
first follow-up and shorten it on later turns — a conversation that has gone quiet twice is
usually finished. Close with a short settling cue rather than a hard cut.

---

## B. Speaking on his own

**Status: works today with zero firmware changes. Nobody has built the policy.**

This is the useful discovery: firmware does **not** gate `response_start` on a preceding user
turn (`src/io/BridgeClient.cpp:135`). It moves to `Responding` and renders whatever it is given.
So the bridge can speak at any moment by sending the ordinary response sequence:

```json
{"type":"response_start","seq":<n>,"intent":"attend","arousal":0.55,"valence":0.60,"text":"..."}
{"type":"audio_stream_start","seq":<n>,"format":"pcm16","sample_rate":22050, ...}
<binary PCM chunks>
{"type":"audio_stream_end","seq":<n>, ...}
{"type":"audio","seq":<n>,"env":0.5,"viseme":"ah","duration_ms":20}
{"type":"response_end","seq":<n>}
```

Everything downstream — mouth sync, RGB, gesture, the `intent` mapping — already works.

### What to build

A **initiative policy** on the host that decides when it is worth speaking. This is the part that
makes it charming or unbearable, so treat the rate limit as the feature:

- A hard floor between unprompted utterances (start at 10+ minutes, tune down carefully).
- Never interrupt an active session, `THINKING`, `SPEAKING`, or a safety state.
- Never speak into an empty room. Require a present person (see D) — talking to nobody is the
  fastest way to make it feel broken rather than alive.
- Suppress at night using the persona's circadian hours (`personas/<id>/behavior.yaml`).
- Back off hard on non-response. If two unprompted openers in a row get no reply, stop for a long
  while. A robot that keeps talking at someone who is ignoring it reads as needy, not curious.
- Route it through the same Character Lock validation as any other response. Unprompted speech is
  not exempt from the persona schema.

A good unprompted line is short, specific, and easy to ignore. "Did the lamp move?" is better than
"Hello! I noticed something! Would you like to talk about it?"

---

## C. Curiosity — noticing someone, then asking about it

**Status: the signals exist, the behaviour does not.**

The firmware already reports what you need. `heartbeat` carries bounded embodiment facts, and the
camera path gives you presence and face boxes (`bridge/vision_service.py`). Firmware-side, the
emotion model now tracks `focus`, `arousal`, `valence`, and `fatigue`, and — as of this change —
per-event **habituation** and a slowly drifting **temperament** baseline
(`src/persona/EmotionModel.cpp`).

That habituation matters for you. The firmware already models the difference between the first
time something happens and the twentieth. Your initiative policy should mirror it: **the thing
worth remarking on is the thing that changed**, not the thing that is merely present. A person who
has been at the desk for an hour is not news. A person who just arrived, or who left and came
back, is.

### What to build

1. Track presence transitions, not presence. Arrival, departure, return-after-absence, and a new
   face versus a familiar one.
2. Let a transition raise a curiosity score, and let that score decay. Only cross into speech when
   it clears a threshold *and* the rate limit in B allows it.
3. Prefer asking to announcing. "You are back early" invites a reply; "A person has been detected"
   does not.
4. Keep the memory rules. Per [CONVERSATION_V2_ROADMAP.md](CONVERSATION_V2_ROADMAP.md), bounded
   session context may live in memory, but raw transcripts are never durable. Only
   schema-validated, privacy-filtered facts survive session close. "Rob usually arrives around
   nine" is a fact; a transcript is not.

---

## D. Letting the model see the room

**Status: the frame path exists, the model has never been given an image.**

`bridge/vision_service.py` already polls the robot's authenticated camera endpoint, parses the
returned PGM, and runs YuNet face detection. Note the frames are **grayscale PGM**, which is fine
for detection and adequate for coarse scene description, but do not expect colour reasoning.

### What to build

1. A **periodic, low-rate** room observation. Every few minutes, not every frame. This is context,
   not a video feed, and every capture costs privacy and latency.
2. Feed the frame to the vision-capable model and keep a short structured scene summary — a couple
   of sentences, or better, a small set of typed fields. Put that summary in the prompt as ambient
   context so answers can reference the room without a tool call.
3. Diff successive summaries. The change between them is the curiosity signal for C, and it is far
   more useful than the raw description.
4. **Privacy is a hard constraint, not a nicety.** Per [PRIVACY.md](PRIVACY.md) and AGENTS.md:
   never persist raw frames, never commit them, and keep the summary privacy-filtered like any
   other memory. A stored description of a person in their home is memory, and it follows the same
   rules as everything else. Make the capture interval and an off switch user-visible.
5. Degrade cleanly. No camera, no pairing, or no vision model must leave conversation fully
   working — the same way bridge loss leaves the local face and wake behaviour intact.

---

## Constraints that are not negotiable

From [AGENTS.md](../AGENTS.md), repeated because all four items above brush against them:

- Audio stays wake-gated at session entry. Conversation v2 reopens the mic *inside* an established
  session; it does not make the robot always-listening.
- A conversation lease never grants or refreshes actuator motion.
- Do not weaken wake-gating, memory privacy, pairing, OTA health, power, thermal, motion session,
  camera-auth, or display gates to make any of this pass.
- One host brain owner, one generation at a time. Owner loss cancels the in-flight turn.
- Bridge or host loss returns firmware to its normal local face, wake, and packaged-prompt
  behaviour.

## Verification

```bash
python -m unittest discover -s bridge -p "test_*.py"      # from the repo root
python bridge/trusted_facts_smoke.py --memory-file output/pc-brain/latest/memory.json --json
python bridge/character_red_team.py --json
```

The trusted-facts smoke must stay silent (`modelInvocations: 0`, `audioPlayed: false`). New
behaviour needs new tests in the same style — deterministic, no hardware, no network.

For anything that reaches the robot, follow the existing evidence discipline: native tests, then
embedded build, then a short supervised run, then longer soak. Do not transfer evidence between
firmware SHAs.
