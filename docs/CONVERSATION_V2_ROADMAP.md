# Conversation V2 Roadmap

Continuous two-way conversation is a post-release feature. The v1 release remains wake-gated:
the user says the wake phrase, Stackchan captures one bounded utterance, replies, and returns to
idle. This document records the next architecture without expanding the current release gate.

## Reusable Pattern

The companion project [RobVanProd/pip-vector-autonomy](https://github.com/RobVanProd/pip-vector-autonomy)
provides a useful local reference architecture:

- an explicit conversation state machine (`IDLE`, `ENGAGED`, `THINKING`, `SPEAKING`, `COOLDOWN`)
- a reply-listen window after robot speech rather than another wake word on every turn
- listener muting plus an echo guard while the robot speaks
- silence timeout and explicit exit phrases
- one serialized model call at a time
- separate recent-turn context, durable facts, and optional speaker memory
- deterministic robot-state and safety checks outside the model prompt

Stackchan should reuse those patterns, not Vector-specific SDK actions, robot locks, executor
code, or unbounded memory. Stackchan's existing bridge owner, wake gate, `PowerCoordinator`,
motion session, camera pairing, and Character Lock remain the authority.

The 2026-07-12 source audit used upstream commit
[`234d1144ff84a5e0d45bd6849cd7c1def8f64935`](https://github.com/RobVanProd/pip-vector-autonomy/commit/234d1144ff84a5e0d45bd6849cd7c1def8f64935).
That repository currently states that no license is granted for reuse or derivative works. This
roadmap therefore records independently implementable architecture observations only; do not copy
its source into a Stackchan release unless its owner adds compatible licensing.

### Stackchan-Specific Adaptation

- Pip estimates speech duration from word count before reopening its listener. Stackchan already
  has authoritative `audio_stream_end`, speaker-idle, playback-stop, and microphone-pause
  telemetry. Reopen capture only after confirmed playback completion plus a measured acoustic
  tail; do not use a word-count timer as the primary gate.
- Pip's listener queue can retain up to 20 pending transcripts and drops the oldest when full.
  Stackchan should allow at most one pending follow-up for the active session. A transcript that
  arrives while `THINKING` or `SPEAKING` is either an explicit barge-in cancellation or a rejected
  busy event, never hidden backlog.
- Pip persists recent raw user/assistant turns. Stackchan must keep its stronger privacy rule:
  bounded active-session context may live in memory, but raw transcripts are not durable memory.
  Only schema-validated, privacy-filtered facts survive session close.
- Pip serializes Ollama calls with an async lock. Stackchan should preserve one host brain owner and
  one generation at a time across robot voice, desktop, and mobile endpoints, with owner loss
  cancelling the in-flight turn.
- Pip periodically touches a robot control reservation while engaged. Stackchan should instead
  renew only its typed conversation lease; that lease never grants or refreshes actuator motion.

## Proposed State Machine

1. `IDLE`: onboard wake word is required. No host conversation microphone window is open.
2. `ENGAGED`: a short reply window accepts follow-up speech without another wake phrase.
3. `THINKING`: capture is closed while STT/Gemma/tools run; barge-in may cancel the turn.
4. `SPEAKING`: speaker playback owns audio priority; the microphone remains echo-guarded.
5. `REPLY_WINDOW`: after playback and the measured acoustic tail, reopen bounded capture.
6. `COOLDOWN`: explicit exit, silence timeout, safety state, bridge loss, or turn limit returns
   the system to wake-gated `IDLE`.

The state machine lives on the host, but the robot must expose enough typed state to make wake,
capture, speaker, and RGB behavior observable. A host crash or bridge loss always returns the
firmware to its normal local face and wake behavior.

### Implementation Status

- `bridge/conversation_session.py` now implements the deterministic host conversation lease,
  acoustic-tail reply window, exit/timeout closure, turn limit, bridge-loss cleanup, and explicit
  barge-in cancellation actions.
- `bridge/test_conversation_session.py` verifies those transitions and confirms the session
  snapshot contains no motion authority.
- `bridge/lan_service.py` now writes `stackchan.conversation-latency.v1` stage evidence for
  capture, STT, brain work, text readiness, first audio, TTS rendering, audio duration, total turn
  time, real-time factor, and the three initial latency/completeness gates.
- `bridge/conversation_latency_report.py --turn-log <turns.jsonl> --json --require-ready`
  summarizes p50/p95/max and refuses readiness when any audio turn misses or fails a gate.
- Firmware playback accounting now stays active until M5Speaker is idle and its microphone pause
  is released, then sends retry-safe `playback_complete` evidence. Default v1 acknowledges the
  frame without opening capture, preserving the v0.2.0 one-wake/one-turn behavior.
- `bridge/lan_service.py --conversation-v2` now maps the first utterance, matching authoritative
  playback completion, acoustic-tail state, bounded follow-up, exit phrases, turn limit, and
  failure cleanup into the session core. It requires configured TTS/downlink and remains off by
  default.
- With `--conversation-v2`, authoritative playback completion now produces a bounded
  `conversation_reply_window` command. Firmware validates it, schedules it with wrap-safe timing,
  and reuses the proven mic cue, RGB, microphone pause, fixed capture, and wake-gated uplink path;
  bridge loss cancels a pending window. Native and host tests cover parsing, bounds, expiry, and
  host transitions. The source path remains opt-in and unpromoted until it passes exact-image
  hardware qualification.
- The remaining core slice is voice-activity-ended capture plus genuinely concurrent cancellation
  of in-flight model generation/playback. The current reply capture is still fixed-length, so it
  proves turn-taking but is not yet natural barge-in.

## Memory Model

- Keep the current privacy-filtered `BridgeMemory` durable facts as the source of familiarity.
- Add a bounded recent-turn ring for the active session only; do not persist raw transcripts by
  default.
- Retrieve durable facts by query relevance and importance. Do not inject or mark every fact as
  used on every turn.
- Run optional consolidation only after a session, against privacy-filtered summaries, with
  schema validation and user/project allowlists.
- Keep speaker recognition opt-in and separate from face detection. Identity never grants motion,
  camera, tool, or memory authority.

## Tool And Grounding Rules

- Trusted local facts such as current local time/date/timezone and remembered preferred name are
  resolved deterministically before Gemma.
- Explicit search requests force one bounded local-first SearXNG research round even if the model
  fails to request it. Research evidence is untrusted data, cited, and cannot write memory.
- Live robot state comes only from typed, expiring heartbeat telemetry.
- Tool syntax never enters spoken text, and a turn may not chain arbitrary tools.

## Acceptance Gates

- First audible reply under 3 seconds for a warm local path; ordinary follow-ups target 1-2 seconds.
- Complete TTS/RVC rendering faster than real time with zero truncation.
- No robot-speech echo accepted as a user turn across 100 reply windows.
- Explicit exit and silence timeout close capture every time.
- Barge-in cancels playback without leaving speaker, mic, or motion state stuck.
- Memory recall is relevant, privacy-filtered, forgettable, and does not recite logs.
- Bridge loss returns to wake-gated local behavior without rebooting or blacking out the face.
- A final no-motion conversation soak precedes an actuator-enabled conversation soak.

## Deliberate Non-Goals For V1

- unattended always-listening capture
- automatic face enrollment or identity-based authority
- model-authored actuator commands outside existing safety coordinators
- cloud-required STT, LLM, search, memory, or TTS
- copying the Vector project's robot-specific actions or executor assumptions
