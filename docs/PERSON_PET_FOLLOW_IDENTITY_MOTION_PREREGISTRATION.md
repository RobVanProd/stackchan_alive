# Person/Pet Follow, Named Identity, and Emotional Motion Preregistration

Status: design-only future lane; no recognition, identity persistence, new detector, protocol,
dashboard control, or motion behavior is enabled by this document.

Date: 2026-08-02

## Requested Experience

Stackchan should distinguish `human`, `dog`, and `cat`, maintain one stable attention target, and
follow that target with his bounded eyes/head behavior. When appropriate, he should learn a name
naturally, use it only when the evidence is strong, and give the owner a trustworthy local place to
inspect, rename, forget, or disable every identity. His movement should express the same character
state as his face and voice without giving a model motor authority.

“Follow” means camera attention, pupils, and bounded two-axis head orientation on the current
Stackchan hardware. This robot has no locomotion authority and must not claim that it can follow a
person or pet through a room.

## Current Evidence

- The paired local vision worker fetches one ephemeral 160x120 grayscale frame and runs hash-pinned
  YuNet face detection. It sends at most four numeric face candidates; it has no species, durable
  track, name, embedding, or identity state.
- Firmware selects one geometric face and fresh audio direction ranks the current face candidates.
  Those candidates are currently human only because YuNet detects faces; firmware has no target-kind
  gate. Bounded attention then passes through `CameraAdapter`, `IntentEngine`, `GazeTracker`,
  `MotionTask`, `PowerCoordinator`, and `ActuationEngine`.
- Historical evidence covers one human face and a visually accepted but slow horizontal follow.
  Final wake/listen/reply follow and multi-person active-speaker selection remain unpassed.
- `robot_embodiment.py` currently describes any fresh camera target as a person. Pet targets cannot
  enter that path until the typed target-kind contract and stale/unknown behavior are repaired.
- Recognition, enrollment, embeddings, and names are intentionally disabled. The existing
  dashboard loopback/header checks are not sufficient owner-admin authority for biometric data.
- Existing affect, mode, idle life, gaze, response gestures, reduced motion, power coordination,
  and final actuator clamps have native coverage. The whole production trace is not byte-
  deterministic by default: boot seeding, demo-intent injection, blink, and saccade paths consume
  random sources. Reproducibility requires fixed inputs/timing/seeds with those sources disabled,
  injected, or recorded by the trace harness. The Python hardware simulator is a protocol/virtual-
  servo rehearsal, not a calibrated dynamics twin.

These are source and historical-evidence facts. No human, dog, cat, identity, camera, or motion
experiment was run for this preregistration.

## Dependency Order

1. Shared truth/safety gates are `PERCEPT-001` for target-loss freshness, `SAFE-001` for durable-
   memory authorization, `PRODUCT-001` for passive motion/rail/torque/thermal truth, and exact-image
   `SEC-002` physical qualification where a later slice depends on HTTP containment.
2. `PERCEPT-002` additionally requires the current camera-auth/privacy contract and final wake/
   listen/reply follow evidence. It may then add anonymous `human|dog|cat|unknown` classification and
   one session target. It is not identity recognition.
3. `IDENT-001` depends on `SAFE-001`, `PERCEPT-001`, `PERCEPT-002`, new authenticated owner-admin
   authority, the private-vault/deletion design, and explicit recognition-enable approval.
4. `MOTION-001` does not depend on `IDENT-001`. It depends on `PRODUCT-001`, exact `SEC-002` physical
   qualification, `PERCEPT-002` for classified-follow scenarios, and a controlled-source final-
   actuator trace harness. Its expected-red/harness work may proceed in parallel with identity
   design after the shared gates, but no physical style candidate can skip no-motion and supervised
   actuator promotion.

## Primary Hypotheses

### H1 — Classified Anonymous Attention

A local class detector plus ephemeral track continuity and a sticky single-target arbiter will
follow a human, dog, or cat more coherently than the current size-ranked face batch, while abstaining
on ambiguity and preserving every firmware safety boundary.

### H2 — Natural Naming Without Guessing

A two-level workflow will feel natural while remaining controllable:

- an explicit wake-gated statement such as “that cat is Luna,” followed by one confirmation while
  the same track remains fresh, may create a session-only nickname; and
- durable recognition requires a separate authenticated owner-admin confirmation, declared consent
  scope, and a verified-deletion-capable identity vault.

Stackchan never invents a name from appearance. Session naming is not biometric enrollment.

### H3 — Deterministic Emotional Motion Style

A small, bounded motion-style vector derived from authoritative affect, mode, energy, reduced-motion
state, and persona constants will improve face/voice/body coherence more reliably than an LLM or a
learned end-to-end motor policy. The hypothesis passes only if full final-actuator traces improve
without hunting, timing, power, thermal, stop, or personality regressions.

## Architecture Boundary

```text
paired ephemeral frame
  -> local class detections (human/dog/cat/unknown)
  -> ephemeral class-separated tracklets
  -> one sticky attention target or ambiguous/none
  -> bounded numeric geometry only across the existing firmware camera seam
  -> CameraAdapter / IntentEngine / GazeTracker
  -> MotionTask / PowerCoordinator / ActuationEngine
  -> bounded final servo command

fresh stable session track + explicit user naming + confirmation
  -> session nickname only
  -> optional owner-admin enrollment proposal
  -> consent + confirmation + private identity vault
  -> recognition result or unknown
  -> bounded host conversational context only
```

Class, track, name, and recognition metadata are observations, never authority. They cannot open a
microphone, claim an active speaker, select the brain owner, retrieve private memory, invoke tools,
write generic memory, enable/refresh motion, change power, control OTA, or authorize identity
administration. A pet can never be marked `audioMatched` or active speaker.

## PERCEPT-002 — Classified Anonymous Following

The first implementation slice is host-first and identity-free:

- Exact classes: `human`, `dog`, `cat`, `unknown`.
- Detection confidence, class confidence, track continuity, and future recognition confidence stay
  separate. No combined “certainty” hides a weak component.
- Track IDs are random/opaque, session-local, bounded, and discarded on worker restart. They do not
  enter durable memory or routine telemetry.
- New acquisition requires minimum detection/class thresholds, a top-two margin, and consecutive
  agreement. Low confidence, a tie, crossing targets, or class conflict becomes `unknown` or
  `ambiguous`; the arbiter briefly retains the prior lock without switching, then emits loss.
- Audio direction may rank fresh human tracks only. Dog/cat selection uses geometry, continuity,
  explicit user attention, and configured preference—not speech attribution.
- The first slice freezes the existing firmware seam to bounded numeric geometry; kind, opaque track,
  and name stay host-side. If geometry alone cannot satisfy the behavior, stop and preregister a
  separate bounded kind/geometry/ephemeral-track protocol extension with native expected-red tests.
- The model may receive only typed, fresh, bounded target context. Stale/invalid/ambiguous input
  projects `unknown`; free-form model output cannot forge an observation.

The first detector experiment should use the existing OpenCV DNN runtime and a small COCO detector
behind a model-agnostic interface. OpenCV Zoo NanoDet/YOLOX and PaddleDetection PicoDet are candidate
sources, not approved package assets. The selected model and weights need exact hash, size, license,
training-source, class-map, latency, grayscale, and release-provenance review before addition. The
existing 160x120 grayscale input may be insufficient; if so, stop and separately preregister an
ephemeral higher-resolution paired capture rather than silently widening camera cost or retention.

## IDENT-001 — Session Names, Durable Recognition, and Removal

### Session Naming

An explicit user statement may create a pending session nickname only when exactly one fresh,
stable, class-compatible target exists. Stackchan asks one bounded confirmation. Low STT confidence,
multiple targets, target loss/change, timeout, correction ambiguity, bridge loss, or name collision
cancels the proposal.

The sole owner is a dedicated in-RAM registry in the main bridge/conversation process, keyed by the
current vision-worker generation plus opaque track ID. It uses a namespace separate from
`BridgeMemory.preferred_name` and every durable memory/delta path. The binding is destroyed on
vision-worker restart or generation change, bridge start/stop, conversation close, track expiry or
loss, target class change, ambiguity, explicit session forget, or its fixed timeout. No nickname or
name-target linkage may enter memory JSON or `.bak`, backups, episodes, open loops, session history,
transcripts, turn logs, routine telemetry, prompt caches, TTS caches, evidence, or generic memory;
the naming turn and generated speech must be redacted before any durable logging. A session nickname
never creates an embedding, template, enrollment artifact, or durable record.

### Durable Enrollment

Durable recognition remains separately default-off. A session nickname can offer only a label-only,
in-RAM proposal. No biometric capture, template computation, index mutation, or vault write begins
until a fresh authenticated owner-admin action and consent step after that proposal. Cancellation,
timeout, nonce expiry, authentication loss, consent withdrawal, target loss/change, worker failure,
or bridge shutdown destroys every pending RAM buffer, capture, template, index entry, and vault
transaction before returning to unnamed behavior. Enrollment then requires:

- an authenticated local owner-admin session stronger than the existing dashboard custom header;
- a fresh single-use nonce, explicit typed confirmation, and recorded consent scope;
- owner attestation that a person consented, or owner/caretaker authority for a pet;
- the exact displayed label confirmed before the record leaves `pending`;
- a local, encrypted, versioned identity vault under ignored private output, never `BridgeMemory`;
- separate human and pet matcher domains, model hashes, thresholds, second-best margins, freshness,
  and multi-frame consistency; and
- no raw capture retention after the in-memory enrollment operation.

A recognized owner is still not authentication. Model changes require explicit re-enrollment; raw
frames are never retained to rebuild templates silently. Unknown/newer vault schemas or index
errors disable recognition and produce unnamed behavior.

### Owner Removal Surface

The local owner-admin surface lists only the minimum useful identity data: owner-chosen display
label, `human|dog|cat`, enabled/pending/revoked state, template count, model/policy version, and an
opaque record ID. Routine status, unauthenticated telemetry, logs, and firmware expose no name, ID,
candidate, score, embedding, or template count.

Every rename, disable, or re-enable operation requires fresh owner-admin authentication and its own
single-use nonce. Rename additionally requires exact new-label confirmation, an atomic label-only
update, and an epoch advance; before success it purges the old label from active-track bindings,
conversational context, prompt/TTS queues, dashboard state, and every runtime cache. It does not
change templates. Disable first marks the record disabled and advances the epoch, cancels inference/
enrollment, removes the record from active indexes, and invalidates active-track bindings,
conversational context, prompt/TTS queues, and dashboard caches; encrypted templates may remain only
in the private vault and must return `unknown`, including after restart. Re-enable additionally
requires a current consent-scope review, compatible model/policy versions, an epoch advance, and an
index rebuilt only from the still-authorized vault record. Revoked consent permits delete, not re-
enable. Rename, disable, and re-enable receipts have the same non-identifying shape as deletion
receipts. Unknown state/version, nonce replay/expiry, auth loss, failed cache invalidation, or
rollback/downgrade fails closed.

Delete/forget is an offline-capable operation that does not require the robot or camera. It:

1. atomically marks the record revoked and advances a recognition/deletion epoch;
2. cancels enrollment/inference and terminates the isolated worker if necessary;
3. removes RAM registries, indexes, templates, aliases, nickname caches, active-track bindings,
   prompt/TTS queues, and dashboard state;
4. removes the record from the primary vault and every managed backup;
5. verifies that generic memory JSON and `.bak`, session history, episodes, open loops, turn logs,
   and managed evidence/cache roots contain no identity linkage;
6. rebuilds the index only from remaining active records and proves the deleted identity returns
   `unknown` after restart; and
7. emits a receipt containing booleans/counts and an opaque operation ID, never the name/template/
   score.

The UI says `deleted` only after verification. Otherwise it says `deletion_pending` or
`deletion_failed`. Non-identifying tombstones prevent an old managed backup from resurrecting a
record. A downgrade that cannot enforce tombstones is blocked unless a full-vault purge verifies.
Cryptographic key erasure and managed-copy deletion are supportable claims; forensic erasure from
Python RAM, SSD wear-leveling, OS snapshots, or uncontrolled external backups is not.

## MOTION-001 — Emotional Motion Policy

Do not add reinforcement learning or an LLM motor policy. Add, if the expected-red experiment
supports it, a deterministic `MotionStyle` projection with bounded dimensions such as:

- amplitude scale;
- velocity/acceleration scale;
- dwell and settling bias;
- gesture intensity/probability;
- gaze lead/lag and loss-search intensity; and
- breath/idle phase and variation limits.

The projection consumes authoritative `EmotionalProfile`, `CharacterMode`, embodied energy,
reduced-motion state, attention state, and generated persona constants. It selects or parameterizes
existing safe primitives; it never contains angles, rail/torque decisions, power decisions, or
session authority. `MotionTask`, `PowerCoordinator`, and `ActuationEngine` remain sole physical
authorities and may decline every proposal.

Tests and comparisons must observe final actuator commands because `ActuationEngine` currently adds
its own idle sine after `IntentEngine`. Measuring only `RobotFrame` would miss the true output.

## Sim/Real Feedback Loop

Use the real C++ components in a controlled-source trace harness; do not reimplement personality
equations in Python. The harness fixes or records every input, cadence, boot/persona seed, demo-
intent source, and blink/saccade/random draw; it must be able to disable production demo injection.
Reproducibility claims apply only to that explicit schedule/source record. Python may orchestrate
scenarios and compute reports only.

The bounded parameter sweep varies:

- intent/motion cadence jitter and stalled steps;
- detector coordinate jitter, dropout, latency, crossing, loss, and reacquisition;
- servo lag, deadband, backlash, speed, sign, and neutral offset;
- audio/power/thermal suppression timing and session expiry; and
- affect/persona seeds and reduced-motion state.

It never randomizes servo limits, safety thresholds, display gate, thermal limits, emergency stops,
or power authority. Simulation failures select a mechanism to inspect; they do not tune around a
safety gate.

Required metrics include final yaw/pitch bounds, maximum velocity/acceleration/jerk, overshoot,
settling time, target RMS error, unwanted target switches, face/body phase coherence, gesture peak/
duration/return-to-base, reduced-motion ratio including downstream overlays, zero writes while
disabled/suppressed/expired, stop latency, task/display budget, and final rail/torque-off evidence.

The physical loop is staged:

1. deterministic native trace sweeps;
2. virtual actuator/protocol rehearsal;
3. display-only/no-motion timing;
4. motion-off paired camera classification/lock evidence;
5. operator-present/body-clear/servo-risk-confirmed low-amplitude HIL with emergency stop;
6. supervised classified-follow run;
7. exact-image integrated 60-minute and later long soak; and
8. verified runner termination, motion/rail/torque off, and post-stop `/debug` snapshot.

No simulator score transfers to hardware. Every physical stage is bound to its exact firmware hash.

## Frozen Expected-Red Tests

Before implementation, preserve named failing cases for:

- species allowlist and class-confidence margin;
- one lock surviving reorder, jitter, and short misses;
- ambiguity/crossing abstention without silent target/name transfer;
- pet targets never acquiring audio-match/active-speaker status;
- stale/invalid pet targets never being described as a person;
- no name, embedding, raw media, or durable ID in the firmware wire or routine diagnostics;
- session naming requiring explicit speech, one stable target, and confirmation;
- session nickname isolation from `BridgeMemory.preferred_name`, memory/backups/episodes/open loops,
  transcripts/turn logs, caches, and evidence, plus expiry on every specified loss/restart boundary;
- durable enrollment rejecting missing owner-admin authority, nonce replay/expiry, consent absence,
  model output, passive room observation, and unauthenticated API requests;
- pending enrollment destroying all RAM/capture/template/index/vault state on cancellation, timeout,
  nonce expiry, auth loss, consent withdrawal, target loss/change, worker failure, or shutdown;
- human/pet matcher separation, threshold, top-two margin, staleness, and multi-frame consistency;
- authenticated rename and disable/re-enable transition/epoch/cache behavior, including nonce replay,
  auth loss, consent revocation, restart, rollback, and downgrade failures;
- delete/restart/managed-backup restore never rematching or resurrecting a tombstoned identity;
- identity never authorizing memory, tools, microphone, camera, motion, power, OTA, or endpoint
  ownership;
- controlled-source final-actuator trace reproducibility and bounded recorded seed variants;
- zero writes under suppression/timeout and bounded target-loss/reacquisition;
- reduced-motion bounds applying after every downstream actuator overlay; and
- identical safety/power decisions when only emotion/persona metadata changes.

## Allowed/Frozen Scope

Likely implementation files must be frozen per slice after expected-red source tracing. Candidate
areas are `bridge/vision_service.py`, a new isolated identity policy/store/worker, typed room and
embodiment projections, focused tests, owner-admin dashboard surfaces, the bounded camera protocol,
`CameraAdapter`, attention/gaze components, affect/intent/style components, native trace fixtures,
launch/package verification, and privacy/vision/protocol documentation.

Frozen throughout: raw-frame non-retention, pairing grammar/authentication, wake and microphone
gates, generic memory sole-authorizer policy, model/firmware authority separation, automatic
recovery, OTA, 50 ms display gate, motion session timeout, servo limits, PowerCoordinator,
emergency stops, private artifacts, and completed evidence. No new cloud service is permitted.

## Stop Conditions

Stop and reject the candidate for any confident wrong class/name, target/name transfer, automatic
durable enrollment, missing consent/admin authority, raw-frame persistence, identity in logs/wire/
generic memory, incomplete deletion, managed-backup resurrection, uncontrolled backup copies,
unlicensed/unhashed models, identity-derived authority, uncalibrated ambiguity thresholds, hunting,
snapping, unsafe jerk/oscillation, bad motion state, missing emergency-stop/post-stop evidence,
display/power/thermal regression, or missing exact source/binary identity.

## Research Basis and Limits

- [YOLOX](https://arxiv.org/abs/2107.08430) and the
  [OpenCV model zoo](https://github.com/opencv/opencv_zoo) show small local object detectors and
  OpenCV-DNN deployment paths; household grayscale performance and exact weight licenses still need
  Stackchan-specific measurement.
- [ByteTrack](https://arxiv.org/abs/2110.06864) supports the hypothesis that low-score detections can
  preserve track continuity, but its published benchmarks do not prove correctness on Stackchan's
  160x120 grayscale camera or justify identity persistence.
- [OpenCV YuNet/SFace documentation](https://docs.opencv.org/4.11.0/d0/dd4/tutorial_dnn_face.html)
  provides a local human face detection/recognition seam; its reference thresholds are not accepted
  until measured on the paired Stackchan pipeline.
- [PetFace](https://www.ecva.net/papers/eccv_2024/papers_ECCV/papers/02660.pdf) and
  [OpenAnimals](https://openaccess.thecvf.com/content/ICCV2025/html/Hou_OpenAnimals_Revisiting_Person_Re-Identification_for_Animals_Towards_Better_Generalization_ICCV_2025_paper.html)
  demonstrate active animal re-identification systems while documenting cross-species/pose/domain
  difficulty. They justify an experiment, not a product claim.
- [DINOv2](https://arxiv.org/abs/2304.07193) is a candidate shadow embedding baseline; it is not a
  validated household pet identity model.
- [Domain randomization](https://arxiv.org/abs/1703.06907) motivates testing across bounded
  variation. This project uses it for deterministic robustness evaluation, not to grant a learned
  policy motor authority or replace physical system identification.

Rollback is removal of the exact atomic slice and its private derived vault/index, while preserving
failed evidence and tombstones needed to prevent identity resurrection. Never restore an insecure
or identity-bearing backup as an operational rollback.
