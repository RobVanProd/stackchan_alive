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
