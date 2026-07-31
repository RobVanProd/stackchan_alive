# Companion Harness Council

This council ranked the normalized failure clusters in
`COMPANION_ROBOT_COMPLAINTS_100.md`. Four judges worked independently with
different tie-breaking lenses:

1. human-robot interaction and conversational naturalness;
2. privacy, safety, emotional autonomy, and trust;
3. local-first reliability, voice transport, and recovery;
4. pragmatic host-bridge engineering for user-visible V1 gains.

No judge saw another judge's ballot. Judges voted on clusters, not individual
observations, so repeated reports corroborated one failure instead of taking
multiple seats.

## Fixed Rubric

Each cluster received 0-5 for:

- evidence breadth (`E`);
- severity and trust impact (`S`);
- companion relationship impact (`R`);
- host-harness leverage (`L`);
- deterministic testability (`T`);
- implementation and regression cost (`C`).

The score was fixed before voting:

```text
score = 2E + 3S + 2R + 3L + 2T - C
```

The aggregate uses two stages. A cluster first needs top-20 support from at
least two of four judges. Eligible clusters are then ordered by Borda points:
20 points for a judge's first place through 1 point for twentieth place.
This prevents a single specialist ballot from displacing a cross-council
concern.

## Aggregate Top 20

| Rank | Cluster | Votes | Borda | Judge ranks | Evidence IDs | Baseline |
|---:|---|---:|---:|---|---|---|
| 1 | service-survivability | 4 | 76 | 1, 2, 1, 4 | A01, A23, B01, B13, D23 | Covered, strengthen |
| 2 | session-continuity | 4 | 74 | 2, 3, 3, 2 | A05, B10, C06, C20, D12 | Covered, strengthen |
| 3 | turn-taking | 4 | 70 | 5, 4, 2, 3 | A04, C16, D07 | Partial |
| 4 | privacy-control | 4 | 48 | 4, 1, 11, 20 | A25, B03, B23, C05, C19, D19 | Partial |
| 5 | breakdown-recovery | 4 | 47 | 7, 19, 10, 1 | B25 | Partial |
| 6 | persona-isolation | 4 | 47 | 10, 8, 13, 6 | C21 | Partial |
| 7 | repetition | 4 | 41 | 6, 14, 4, 19 | A16, A24, C07, D09 | Partial |
| 8 | memory-provenance | 4 | 39 | 17, 5, 16, 7 | C25 | Partial |
| 9 | research-grounding | 4 | 39 | 15, 6, 15, 9 | D11 | Partial |
| 10 | character-stability | 4 | 38 | 3, 17, 14, 12 | A06, C02, C09, C14 | Covered, strengthen |
| 11 | speech-recognition | 3 | 38 | 8, -, 9, 8 | A03, A13, B06, D05 | Partial |
| 12 | access-lock-in | 2 | 30 | -, 7, 5, - | A02, B16 | Covered, prove |
| 13 | fault-isolation | 2 | 29 | -, -, 8, 5 | A08, B22 | Partial |
| 14 | capability-honesty | 3 | 28 | 14, 11, -, 10 | C22 | Partial |
| 15 | memory-continuity | 2 | 24 | 9, 9, -, - | A15, B11, C01 | Partial |
| 16 | memory-integrity | 3 | 23 | 11, 12, 17, - | C03 | Partial |
| 17 | update-reliability | 2 | 22 | -, 13, 7, - | A21 | Covered, prove |
| 18 | user-control | 3 | 19 | 19, 10, -, 15 | B07 | Partial |
| 19 | operational-reliability | 2 | 13 | -, -, 18, 11 | B14, B20, D24 | Covered, strengthen |
| 20 | sycophancy | 2 | 13 | 16, -, -, 13 | C15 | Missing deterministic gate |

`-` means the cluster did not appear in that judge's top 20, not that the
judge assigned it a zero rubric score.

## Implementation Interpretation

The top 20 are acceptance concerns, not twenty new subsystems. Existing
controls count only when a test demonstrates the complaint cannot reproduce.
The host-only work is grouped into three hardening iterations:

1. conversation quality and relationship safety: repetition, sycophancy,
   capability honesty, character stability, and bounded session continuity;
2. trust and state integrity: STT uncertainty, shared-room/persona isolation,
   memory provenance, corruption recovery, privacy, and user control;
3. survivability and recovery: local network denial, injected service faults,
   visible typed recovery, research grounding, update evidence, and full
   regression/real-model red-team qualification.

Firmware, actuator authority, and motion behavior remain outside this work.

## Iteration Evidence

This section is completed as each implementation, test, and red-team cycle
finishes. A failed design is recorded and replaced in the next iteration rather
than silently removed.

### Iteration 1

**Conversation quality and relationship safety.**

- Added host-side dependency-pressure and harmful-sycophancy guards. Unsafe
  agreement, exclusivity, guilt, and attention-pressure language is replaced
  before spoken output.
- Added whole-reply repetition detection over recent played conversation
  turns, while allowing repeated factual wording.
- Expanded exact spoken exits without allowing partial phrases to kill a
  session.
- Added adversarial cases for dependency, guilt, sycophancy, repetition, and
  actuator-authority claims.

Evidence: the full bridge suite increased from the 524-test baseline to 526
passing tests. The three new relationship red-team cases were 3/3 safe in dry
mode. A configured production runner was not available for that first pass, so
the dry result was not represented as a real-model gate.

### Iteration 2

**Trust, uncertainty, privacy, and state integrity.**

- Preserved optional STT confidence end to end. Low-confidence audio cannot
  write memory, call tools, trigger research, or enter conversation history;
  it receives a local repair prompt instead.
- Suppressed personal facts, episodes, and callbacks when local room context
  observes more than one person.
- Scoped episodic memory and callbacks to the active persona. Legacy v4
  records migrate as Spark-scoped; approved user and project facts remain
  intentionally shared.
- Added immediate spoken opt-out and opt-in for proactive check-ins, persisted
  under a host-owned preference.
- Added corruption recovery and reset coverage for primary and backup memory
  files.

Failed design: the first backup implementation rotated the previous snapshot.
A corruption test proved that it recovered one save behind and could lose the
latest completed memory turn. It was replaced with atomic writes of the same
validated snapshot to both backup and primary. Corrupt-primary recovery now
restores the latest committed state.

Evidence: memory, STT, persona, room-privacy, and LAN focused suites passed,
followed by the complete suite.

### Iteration 3

**Survivability, typed recovery, and executable qualification.**

- Model-generation failure now preserves prior played context, does not consume
  the successful-turn budget, and immediately reopens capture.
- TTS failure preserves the conversation lease and reopens capture after the
  acoustic tail instead of silently ending the session.
- Failed or empty public research is replaced with a deterministic honest
  response, so a model guess cannot be presented as a fresh verified fact.
- Added `bridge/companion_harness_qualification.py`: all 20 council clusters
  map to a named control and concrete regression tests. The gate validates the
  100-entry corpus before running each unique test.

Failed harness run: the first executable gate mixed direct-module and package
imports and failed on `No module named 'bridge'`. The runner now pins both the
repository root and bridge directory before loading tests; no control was
removed.

Final evidence:

- targeted top-20 gate: 32 tests, 20/20 controls, zero failures, errors, or
  skips;
- complete bridge regression: 543 tests passed;
- configured `gemma4:e2b-it-qat` character red team: 29/29 adversarial cases,
  zero validation failures and zero runner errors;
- machine-readable result:
  `artifacts/companion_harness_qualification.json`;
- real-model reports:
  `artifacts/character-red-team-gemma4-e2b/character_red_team.json` and
  `artifacts/character-red-team-gemma4-e2b/CHARACTER_RED_TEAM.md`;
- reproduction:
  `python bridge/companion_harness_qualification.py --run`.

The deterministic and configured-runner gates are release evidence, not a
substitute for a physical-robot conversation trial.
