# World Model

Status: normative bounded-perception contract; not an implemented sensing claim
Baseline: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`

## Purpose

The world model provides conservative temporal continuity across authorized, sanitized
observations. It helps Stackchan distinguish what is currently observed, last known, inferred,
contradicted, unavailable, or unknown. It never creates identity, private-trait, ownership, intent,
or causality claims from ambiguous sensor data.

## Permitted Observations

- Presence transition and coarse person-count band.
- Coarse gaze/attention target when supported, without identity.
- Coarse object/category continuity when enabled and qualified.
- Lighting band/change.
- Coarse sound direction.
- Robot relocation or pickup indication from authoritative sensors.
- Touch/proximity state from typed firmware telemetry.
- Camera, sensor, network, bridge, and brain availability with freshness.
- Coarse private/shared/empty/unknown social setting.

Raw frames, audio, embeddings tied to people, biometric templates, secrets, precise private
locations, and arbitrary transcripts are not world-state records.

## Observation Record

Every observation contains type, sanitized value, source component and authority, boot/session,
observed and expiry times, confidence, privacy class, evidence reference, and contradiction links.
A derived observation also names the reducer and source observation IDs.

Confidence does not authorize a privacy-sensitive claim. Presence count does not establish speaker
identity, addressed-to-robot status, relationship, intent, or permission to retrieve memory.

## Freshness and Decay

- Sensor availability and robot/bridge connection require current measured evidence, not only a
  historical ready/debug value.
- Expired observations become stale/unknown and cannot satisfy a current-perception claim.
- Last-known values may remain visible only with their timestamp and stale label.
- Presence, gaze, sound direction, and active-speaker-like estimates use short source-specific
  expiries and hysteresis to avoid flicker without manufacturing continuity.
- A service outage preserves no current “clear room” or “person present” conclusion.
- Wall-clock and monotonic/boot identity are both recorded so restart cannot refresh old evidence.

The observed dashboard case in `PROJECT_STATE.md` is a required regression fixture: a roughly
64,909-second-old ready heartbeat plus no current robot socket/reachability must not project
`connected`, `ready`, or `operational`. The historical telemetry can remain last-known/stale.

## Contradiction and Source Priority

Authoritative device telemetry wins only within its domain and freshness window. A host desire to
speak does not prove a microphone window; a commanded expression does not prove playback/motion
completed; a camera summary does not override hardware sensor availability. Conflicting valid
observations are preserved and resolved by typed policy or remain uncertain.

The system never infers a brownout, thermal fault, USB cause, robot freeze, or other hardware root
cause without matching telemetry. Isolated probe timeouts and short atomic-file sharing violations
remain distinct from robot failure.

## Behavior Coupling

A production behavior may consume an observation only when:

1. the source is authorized for the claimed domain;
2. schema/privacy validation passed;
3. freshness and minimum confidence pass;
4. contradictions are resolved or verbally disclosed;
5. social-setting suppression and user controls pass;
6. the behavior has a bounded fallback for unknown/unavailable.

Speech must distinguish “I can see/hear/sense now,” “I last observed,” “telemetry reports,” “I
remember,” and “I infer.” Unknown is preferable to an embodiment overclaim.

## Identity and Multi-Person Boundary

Automatic identity recognition is outside this contract and requires explicit approval. Session-
scoped anonymous tracks may support bounded attention but cannot retrieve person-specific memory.
Speaker attribution and addressed-to-robot status remain unknown unless a separately authorized,
qualified mechanism establishes them. In shared settings, personal memory and proactive callbacks
default to suppression.

## Failure and Privacy Behavior

- Camera unavailable: report availability only; do not infer room contents.
- Stale presence: expire it; do not treat it as absence or presence.
- Bridge/brain unavailable: firmware remains locally graceful; world state gains no fallback
  authority.
- Parse/schema failure: reject and count without logging private payload.
- Repeated contradiction: reduce confidence and request safe clarification only when useful.
- Diagnostics: expose source, age, confidence, state kind, and failure counts, never raw frames or
  audio.

## Shadow-Mode Evaluation

Use synthetic and sanitized recorded summaries to measure false-current claims, expiry accuracy,
presence transition precision, embodiment-claim precision, perception-to-reaction latency,
shared-room restraint, contradiction handling, outage recovery, and bounded storage. Compare shadow
decisions with current production; no shadow observation may alter behavior before a separate
preregistered promotion experiment.
