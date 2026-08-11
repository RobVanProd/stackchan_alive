# Current Capability Audit

Audit baseline: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`
Audit date: 2026-08-02
Status: all ten read-only domains reconciled; independent documentation review in progress

## Evidence Language

- **Implemented:** present in source at the audited commit.
- **Source-tested:** relevant deterministic tests/probes passed.
- **Source-reproduced defect:** a safe source-level or synthetic probe demonstrated the failure.
- **Physically qualified:** accepted evidence is tied to an exact firmware hash.
- **Unqualified:** not established; this does not mean physically failed.

The audit did not inspect private memory values, raw microphone/camera content, credentials, or
pairing codes. It did not restart services, call a robot write endpoint, flash, move, or alter live
production state.

Replayable per-role source symbols, commands, aggregate probe results, and remaining uncertainty
are preserved in `docs/audits/20260802_READ_ONLY_WAVE.md`.

## Repository and Evidence Truth — AUDIT-01

The audit branch is based on fetched `origin/main`, not the 75-commit-stale local `main`. All
non-generated local/remote branches, merge bases, ahead/behind counts, patch equivalence, PR states,
worktrees, and dependency domains were independently recomputed in `BRANCH_LEDGER.md`.

Current-main source gates are green in the documented build context: native 289/289, bridge
543/543, silent trusted-facts smoke, three release/evidence contracts, and secret-free
`stackchan_release_full` compilation. The default shared PlatformIO core fails before source
compilation because its pioarduino framework directory is absent; pinning documented
`C:\spio\pioarduino` passes. This is an invocation/tool-context defect, not a current-source build
regression.

The reproducible-build PR has a useful deterministic stamp mechanism but is stale/conflicting. Its
current candidate config runs the hook twice for `stackchan_wifi`, derives only 12-character HEAD
plus tracked-dirty status, ignores untracked files/dirty content identity, and leaves override/
disable environment controls ungoverned by release packaging. All three public packaged
environments and private evidence-bearing domains need clean paired-hash tests.

No branch or worktree is safe to delete solely because its code is merged: a production-support
worktree has a tracked modified GIF, others may contain untracked/ignored evidence, and a detached
release worktree remains operationally inventoried.

## Conversation and Turn Taking — AUDIT-02

Implemented and source-tested strengths include wake-gated initial capture, endpointed PCM,
bounded session context, silence/exit closure, matching authoritative playback completion before a
reply window, duplicate/stale completion rejection, cancellation token/process/audio cleanup, and
deterministic weather/research correction flows.

Three source-reproduced P0 trust defects block natural-conversation closure:

1. speaker start/chunk/finish failure may never emit `playback_complete`; host `SPEAKING` has no
   timeout and can persist indefinitely;
2. model/TTS failure changes host state but sends an error rather than firmware `ReplyWindow`, so
   host and robot disagree about capture availability;
3. the host's 10-second capture commitment can time out before firmware's 12-second endpoint and
   reject a valid utterance ending at 12 seconds.

The firmware wake gate also uses rollover-unsafe raw millisecond comparisons. Multi-party privacy
suppression is useful but there is no qualified speaker attribution, addressed-to-robot gate, or
two-voice arbitration.

Physical Conversation v2, over-speaker barge-in, echo rejection, 100 reply windows, three warm
under-three-second turns, and no-motion conversational soak remain unqualified. Protocol/roadmap
text still describes older 4.8-second/fixed-initial-capture behavior.

## Memory and Continuity — AUDIT-03

Memory v4 implements bounded schema/caps/expiry, atomic replacement, backup fallback, migration,
exact-key recall, deterministic explicit remember/forget parsing, privacy filters, shared-room
suppression, persona-scoped episodes/open loops, and stale-distillation revision protection.
Trusted local facts resolve host-side before model inference; research output has memory actions
cleared.

The most severe source-reproduced violation is authorization: an ordinary model response can add a
valid durable write or wildcard forget without a matching explicit user command, and every
normalized action is applied. A generic third-party detail can also evade the finite-name/
possessive privacy filters.

Other trust defects:

- the earliest due callback can replace an unrelated answer;
- topic-specific explicit recall can return the newest unrelated episode;
- distilled episodes have schema/privacy checks but no entailment, confidence, or source evidence;
- durable corrections are last-write-wins without supersession history;
- a structurally invalid but parseable primary can suppress a valid backup;
- interrupted sequential primary/backup reset can resurrect memory;
- durable global versus persona/project scope is implicit and incomplete.

The current probe's exact/paraphrase `1.0` and injected-fact `0.0` results do not measure these
end-to-end paths. Physical Memory v4 and longitudinal false-memory, provenance, callback precision,
restart, and deletion durability remain unqualified.

## Affect and Self State — AUDIT-04

Firmware has genuine uptime-scoped computational affect: arousal, signed valence, focus, fatigue,
event response, decay, habituation/recovery, baseline drift, sleep pressure, and causal influence on
face, motion, RGB, speech cues, sleep, and heartbeat. Fault/sleep priority and low/critical energy
hysteresis are explicit. This is not evidence of subjective feeling.

Current release behavior is not reliably grounded because `IntentEngine` boots demo enabled and
injects random synthetic FaceDetected/WakeWord/Thinking/Response/Idle events every 2.5-6 seconds.
The native suite confirms demo prevents sleep; only a manual serial `demo off` disables it, and no
release/soak contract enforces off.

Phrase streaming clamps response-start valence to `[0,1]`; a `-0.72` concern value reached firmware
as `0.0` while TTS retained `-0.72`. Cross-field validation also accepted happy text/earcon with
safety mode and contradictory arousal/valence.

Relationship safety is prompt-backed but lexically enforced: four clear guilt/exclusivity/
discouraging-human-contact paraphrases passed unchanged. Affect resets at reboot; no durable
temperament contract exists, and current-main integrated physical affect is unqualified.

## Perception, Attention, and World Grounding — AUDIT-05

Positive boundaries include bounded transient grayscale face processing, hash-pinned YuNet,
allowlisted room summaries, default-off/cancelable/rate-limited room observation, explicit
identity/private-trait prohibitions, gaze stale decay, and preservation of firmware motion/power
authority. Raw frames are not routine prompt/status persistence.

A source-level false-presence chain exists: FaceLost clears `targetValid` but retains historical
`lastSize`; every lost update refreshes `lastEventMs`; heartbeat freshness checks nonzero size plus
event age but ignores target validity. A 1 Hz empty detector can therefore keep
`camera_target_fresh=1`, which host logic converts to current presence for initiative and sensing
claims.

Separately, prompt room text expires but the relationship-card consumer reads an age-free cached
summary. A stale one-person state can continue allowing preferred name, episodes, callbacks, and
approved facts after the social setting becomes unknown.

Other gaps include cached debug resurrecting dashboard connected/operational state, room summaries
without source/confidence/contradiction, source-overwriting/double-counted transitions, indefinitely
valid target diagnostics after worker loss, inconsistent private-address/redirect policy between
camera clients, and privacy documentation that incorrectly says release camera endpoints are
compiled out.

Final active-speaker behavior, real room-model accuracy, camera-follow, and calibrated passive
proximity remain unqualified, not failed.

## Initiative and Planning — AUDIT-06

Current initiative is release-default-off in its policy config, enforces a ten-minute floor,
fresh-presence/session/mode/circadian/reply/retry gates, and adds a six-hour backoff after two
ignored openers. It omits memory/research context, opens no microphone window, uses normal
cancellation for explicit user activity, and has no direct actuator/power/OTA/pairing/credential
fields. Firmware remains physical authority.

It is an event/curiosity threshold, not an agenda. Decisions have reason/prompt/score but no
evidence reference, confidence, expected user value, why-now/why-not-silence, privacy/social class,
or open-loop/shared-project integration.

Source-reproduced defects:

- host thermal/power suppression checks fields that production heartbeat does not send; a
  2-percent/critical-energy shaped heartbeat can still yield arrival initiative;
- after reservation, later sleep/safety/presence heartbeat does not cancel or revalidate model/TTS;
- proactive guilt/attention-debt paraphrases pass the same lexical validator;
- dashboard disable is runtime-only and can revert to stored true after restart;
- one presence flap or one room arrival can manufacture/double-count curiosity.

The source contains useful restraints but no source-matched physical or longitudinal initiative
evidence for acceptance, annoyance, silence, shared-room behavior, or in-flight safety transition.
It remains unpromoted.

## Multimodal Expression — AUDIT-07

Face, motion, and RGB consume a shared `RobotFrame`; RGB uses the same mode/emotional profile.
Think holds until real audio, Speak begins on audio onset, PCM windows drive mouth state with a
160 ms stale timeout, and semantic gesture only changes bounded targets under firmware actuator/
power authority. Affect habituation and host near-duplicate response checks provide useful
repetition defenses.

The signed-valence defect is on the active phrase-streaming path and creates a direct cross-modal
contradiction. A second high gap is that validated model earcon never enters `BridgeTurn` or the
wire response; firmware derives earcon from intent, while Wi-Fi builds cancel local response
speech/earcon playback during streamed audio. The documented zero-translation earcon contract is
therefore not implemented.

Partial TTS failure closes protocol correctly but can leave the user with an abrupt partial
sentence and only transient error expression. DirectML fallback changes voice identity without a
coherent multimodal degraded-voice cue. One Spark packaged Sleep cue references a safety/error
audio transcript in non-Wi-Fi scope. Response gesture is a safe command/target, not telemetry proof
that a physical nod/shake completed.

Current-main expression changed substantially after the accepted exact physical image. Speaker,
voice, RGB, gaze, sleep, gesture, timing, and integrated actuator coherence at this commit are
unqualified, not failed.

## Product and Onboarding — AUDIT-08

Release/OTA tooling, Android setup/recovery, loopback/private dashboard boundaries, verified motion
command paths, diagnostics export, and honest incomplete-signing/target-install documentation are
strong. The dashboard passive presentation has two P0 truth defects: it can call motion safely
stopped when only `motion_enabled=false` while rail/torque remain true, and it can report Bridge
Ready/operational from stale cached debug after failed refresh. Unknown thermal telemetry is also
rendered as clear.

Desktop companion renders forget/remove/Wi-Fi management controls with default no-op callbacks,
omits registry state, silently discards many operation failures, and retains phone-specific setup
copy. The overall flow remains a lab bring-up: launcher defaults to one robot IP, normal operation
has several runtime/model/research/voice/pairing prerequisites, and consumer Wi-Fi still needs a
robot menu or serial step. There is no single truthful first-run readiness checker.

Status/update docs are fragmented: Conversation v2 is described as post-release while the default
launcher enables it; desktop Python packaging statements conflict; updates are manual; signing,
tag, target-install, and human-review gates remain incomplete. These are documented or
source-reproduced product gaps, not claims that a target-device install failed.

## Privacy, Dependency, and Ethics — AUDIT-09

Local-first intent, wake gating, camera pairing, loopback/same-origin dashboard writes, OTA token/
digest validation, model-to-physical-authority separation, secret-free packaging, and research-
memory isolation are strong boundaries in their covered paths.

Two critical source findings are stop-ship:

- the production PC launcher binds all interfaces, but WebSocket admission does not enforce the
  existing firmware path/protocol/device signals, configured peer, or browser-origin boundary;
  sensitive messages can be processed before trusted robot hello, blank endpoint ID bypasses owner
  enforcement, and one unauthenticated client can monopolize the serial server;
- Wi-Fi-enabled firmware HTTP mutating controls reach motion-resume/recovery/reboot-class handlers
  without the camera pairing gate. `stackchan_release_full` and other Wi-Fi profiles are affected;
  default non-Wi-Fi `stackchan` is not, and OTA remains separately token-gated.

The first was synthetically confirmed and the live exposed bridge listener was stopped with user
authorization and zero established clients. The firmware path was source-observed only and never
exercised on hardware.

Other gaps include open-ended/lexical sensitive-memory categories, semantic dependency-policy
bypass, mutable GitHub Action refs, missing Gradle distribution checksum, unhashed Python inputs,
DNS validation/connect separation in research fetch, and contradictory production camera docs.
The intended existing signals are sufficient for non-cryptographic host admission hardening; they
do not establish cryptographic robot identity.

## Research and Evaluation — AUDIT-10

The current 100-complaint artifact has 100 IDs across 59 clusters, while executable qualification
covers a ranked top 20 and leaves 50 rows/39 clusters without an executable-control/disposition
trace. The top-20 gate is useful but must not be described as semantic coverage of all complaints.

Physical qualification has strong provenance/mechanics, but subjective natural/grounded/accurate
booleans lack trial IDs, observable anchors, rubric version, counterfactual, or second rater.
Research acceptance proves bounded routing, public URL/excerpt, and transport success—not source
authority, freshness, claim-citation entailment, contradiction handling, or correctness. Memory v3
and v4 have the same `1.0` result on a small lexical fixture; three-turn latency and two-opener
initiative gates are engineering controls rather than longitudinal experience distributions.

Ten primary-source mechanisms and their transfer limitations are recorded in
`RESEARCH_LEDGER.md`. The smallest measurement improvement is a versioned complaint-to-control/
deferred/out-of-scope trace, followed by anchored public/synthetic research-grounding trials.

## Current Physical Evidence Boundary

The latest accepted deployment record is source `ce66f8a0fadfadbc07eb59124522267ba66ee70a`,
firmware SHA-256 `69d3db27f2d7197799fdc08ff3c1dc4d6e3011724fe29899367dc016e48ebfa8`,
with a checked 28,807-second all-feature actuator soak and 5,643/5,643 polls. Direct robot debug is
currently unreachable and the installed hash is unknown, so that accepted hash is not asserted as
currently installed and none of its evidence transfers to current main.

## Cross-Domain Failure Chains

The highest-risk findings are coupled even though their fixes should remain small:

- false/stale presence can permit personal projection, add initiative score, and ground a false
  present-tense sensing claim;
- demo affect can drive sleep/expression independently of real events, while signed-valence loss
  makes voice and face disagree;
- unprompted model memory mutation plus incomplete third-party filtering can turn ordinary output
  into durable private falsehood;
- an irrelevant due callback plus forced answer replacement can combine bad retrieval with bad
  conversational priority;
- stale dashboard state can hide the difference between historical telemetry and current
  reachability during recovery;
- initiative can begin under one state and continue after a later safety/sleep transition because
  production heartbeat and cancellation contracts are incomplete.

These chains support building typed provenance/freshness/authority shadow projections, but they do
not authorize a broad Continuity Core behavior switchover.
