# Aliveness Workplan

Status: living work ledger for the August 2026 aliveness audit
Baseline audited: `99ff6010` (main, 2026-08-13)
Working branch: `agent/aliveness-tier1-tier2`

This document tracks the defects and improvements identified by the 2026-08-13 full-repo
aliveness audit, their fix status, and their evidence status. It follows the repository
evidence discipline: **"Done in source" never implies physical qualification.** Any row that
changes firmware behavior remains physically unqualified until the exact flashed SHA-256
passes its own gates.

Status legend:

- `todo` — not started.
- `in-progress` — being edited on the working branch.
- `done-source` — implemented and passing native/host tests; not physically qualified.
- `qualified` — exact-image physical evidence recorded (owner-run; out of scope for this branch).
- `blocked` — cannot proceed; blocker named in Notes.

## Tier 1 — Firmware aliveness fixes (source-only, native-testable)

| ID | Task | Status | Notes |
| --- | --- | --- | --- |
| AL-01 | Fix dropped persona face channels: `FaceAnimator::samplePose` must compose `faceX`/`faceY`, mouth width/corner deltas, lid tilts, and eye corners from the incoming `RobotFrame` instead of discarding them (`src/face/FaceAnimator.cpp:251-263`, `src/face/ProceduralFace.cpp:45`). Unify on one `BreathRhythm` so face and body share one breath. Add a composed-path native test. | done-source | Restores IdleLife breath translation, yawn faceY, GazeTracker face shifts, and sound-orientation faceX to the rendered face. |
| AL-02 | Remove `ActuationEngine` idle sine sway (`src/motion/ActuationEngine.cpp:201-205`) which re-adds the metronomic motion `IntentEngine` explicitly removed; jitter the fixed 14.3 s `IdleLife` gaze-drift sine (`src/persona/IdleLife.cpp:51-56`). Also deletes the dead `src/motion/Blink.hpp`/`Saccade.hpp` duplicates and the now-unused `STACKCHAN_SERVO_IDLE_SCALE` flag. | done-source | HeadGaze look-and-hold remains the only idle head-motion source. |
| AL-03 | Seed `FaceAnimator::rng_` (fixed `0x51A7C0DE`) and the `IdleLife`/`BreathRhythm`/`HeadGaze` hash streams from hardware entropy at boot so each power-on plays a different idle sequence. Keep deterministic seeding available for native tests. | done-source | Entropy injected at construction/begin; native tests pass fixed seeds. |
| AL-04 | Persist `EmotionModel` long-timescale state (baseline temperament, habituation familiarity) to NVS with a bounded slow write cadence; restore on boot. Fix the unreachable natural-wake condition (`quietSeconds_` pins `sleepPressure()` at 1.0 while asleep, so `fatigue < 0.35` can never occur). | done-source | Temperament now survives power cycles; sleep can end naturally. |
| AL-05 | Make `applyCircadian`/`applyAmbient` dt-scaled and idempotent per phase change instead of unbounded impulses per received message (`src/persona/EmotionModel.cpp:250,280`); remove the double-application path in `main.cpp:9527-9532`. | done-source | Prerequisite for any real clock/ALS circadian source. |

## Tier 2 — Bridge character fixes (host-side)

| ID | Task | Status | Notes |
| --- | --- | --- | --- |
| AL-06 | Remove the `[0,1]` valence clamp on the firmware response-start frame (`bridge/lan_service.py:2932`) so face valence matches TTS valence (`[-1,1]`). Completes the open half of AFFECT-001. | done-source | Concerned voice no longer paired with neutral face. |
| AL-07 | Make `pip` and `bolt` real characters: distinct traits/prompt rules, remove the inherited "answer only: I am Stackchan Spark" line (`personas/pip/character.yaml:68`, `personas/bolt/character.yaml:68`). Harden `scaffold_persona_pack` to refuse emitting prompt rules that name the source persona. | done-source | Also verifies Glow retains the Spark safety rules it silently dropped. |
| AL-08 | Move the hardcoded Spark-only conversation style (`SPARK_CONVERSATION_STYLE`, `bridge/character_harness.py:820-821`) into per-pack YAML so every persona gets a style palette; stop loading `DEFAULT_PERSONA` at module import. | done-source | Personas other than Spark are no longer structurally blander. |
| AL-09 | Give failures a voice: model/TTS failure paths speak one short in-character line instead of returning silence (`bridge/lan_service.py:3543`, `3726-3731`, `3905-3906`). TTS-misconfigured no longer reports a fully successful silent turn. | done-source | Failure lines routed through the persona spoken-line table. |
| AL-10 | Persist bounded affect across sessions: mood baseline and rapport in a dedicated `affect_state.json` beside the memory file (`bridge/affect_state.py`), injected as one coarse host-derived prompt line. Deliberately **not** in `BridgeMemory`: `MEMORY_CONTRACT.md` gates new memory-schema work behind the AUDIT-03 repairs, and this state carries no user data. | done-source | Hard bands mirror the firmware temperament bands; corrupt files clamp to neutral; rapport relaxes over idle days. |
| AL-11 | Initiative fixes: pass the relationship card and recent-context lines into `run_initiative` (`bridge/lan_service.py:2759-2760`) and open a bounded reply window (`conversation.wake()`) after a proactive line so the user can answer without re-waking. | done-source | A robot that speaks first can now hear the answer. |
| AL-12 | Vary character beats: the `sha256 % 16` quip selection now mixes a per-process rotation salt (`STACKCHAN_BEAT_ROTATION_SALT` overrides for deterministic runs), so the same question after a bridge restart draws a different quip. | done-source | Within-session anti-repetition unchanged; cross-session repetition broken by the salt. |

## Tier 3 — Documentation truth sync

| ID | Task | Status | Notes |
| --- | --- | --- | --- |
| AL-13 | Update stale P0 rows for fixes already merged on main: demo-mode default (PR #230), capture lease 13.5 s (PR #226), dashboard stale readiness (PR #222) in `EXPERIENCE_SCORECARD.md`, `TASK_LEDGER.md`, `CURRENT_CAPABILITY_AUDIT.md`, `CONTINUITY_GAP_ANALYSIS.md`, `PROJECT_STATE.md`, `docs/BRIDGE_AI_HANDOFF.md`, `docs/CONVERSATION_V2_ROADMAP.md`. | done-source | Genuinely-open P0s (valence clamp, F3 vision, F1 error paths) now stand out. |
| AL-14 | Record this workplan's changes in the ledgers without claiming physical evidence. | done-source | This file is the tracking source of truth for the audit follow-up. |

## Explicitly out of scope for this branch

- Flashing any image, OTA, soak, or physical qualification (owner-run; see
  `docs/ARRIVAL_DAY_RUNBOOK.md`). All firmware rows above stop at `done-source`.
- F3 vision bring-up (requires flashing `stackchan_release_forensics_vision`).
- F1 error-path physical qualification (`host-response-wire-clean` report).
- Conversation v2 promotion, PERCEPT/IDENT/MOTION preregistered tasks.
- The Continuity Core typed journal (Milestone 2) — design docs remain normative-only.

## Audit findings intentionally left open (tracked, not fixed here)

| Finding | Why deferred |
| --- | --- |
| `lan_service.py` god module / ~800-line `_run_utterance_end` | Structural refactor; high regression risk near unqualified Conversation v2 paths. |
| Pure-Python reply-PCM speech gate cost | Optimization; needs latency evidence before/after. |
| Per-turn persona pack reload from disk | Optimization; cache invalidation policy needs design. |
| Two parallel TTS paths in `lan_service.py` | Consolidation belongs with the F1 error-path work. |
| Frozen-dataclass mutation via `object.__setattr__` in `bridge_memory.py` | Belongs in the Memory v5 schema follow-up after AL-10 lands. |
| Servo 2 Hz release resampling and duty freeze | Power/actuator policy decision; owner call, needs hardware evidence. |
| Boredom/curiosity drive state | New behavior, requires preregistration per `TASK_LEDGER.md` discipline. |
