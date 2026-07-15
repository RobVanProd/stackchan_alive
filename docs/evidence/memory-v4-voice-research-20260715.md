# Memory v4, Voice Forensics, and Research Evidence

Date: 2026-07-15
Scope: host implementation plus one stale native persona-text expectation sync; zero `src/`
changes; zero new runtime dependencies.

## Voice Forensics

| Probe | Measured result | Classification |
| --- | --- | --- |
| P0 active path | `rvc_tts_client.py` -> `127.0.0.1:5055`, `cuda:0`, `pm` | H1 rejected |
| P1 identical call 1 | convert `59578.83 ms`, infer `59578.82 ms`, queue `0 ms` | cold conversion state observed |
| P1 identical call 2 | convert/infer `3234.51 ms`, queue `0 ms` | archived warm ROCm rate recovered |
| Worker lifecycle | uptime `4407.77 s`, count `7`, load `1139.98 ms`; no restart | process/model remained resident |
| P2 device truth | `AMD Radeon RX 7800 XT`, available | H3 not supported by adapter identity |
| P3 contention | Ollama loaded at `100% GPU`; unloaded cell not run | H4 unresolved |
| P4 environment | current/archive Torch `2.9.1+rocm7.2.1`, RVC `0.1.5`; archived driver absent | exact driver diff unavailable |

Classification: H2 is supported in the narrow measured sense that conversion warmth was absent on
the first call after idle even though the worker stayed resident. H5 is rejected by the immediate
`3.23 s` repeat. H4 remains a hypothesis because stopping the active Ollama brain was prohibited.
No live process was restarted or rerouted. Both worker health schemas now expose adapter identity
and availability; the full-system soak now fails on uptime regression or conversion-count reset.

The qualified DirectML artifact remains
`output/voice-lab/directml-rvc-pm-full-index-20260710/benchmark.json`: median RTF `0.222`, warm
conversions `0.4238-0.6320 s`. `FIRST_DEPLOY_STATUS.md` now distinguishes that qualified production
configuration from the observed post-reset ROCm rollback session.

Proposed PR #199 gate wording, pending owner approval: **rollback path integrity documented with
measured latency, and DirectML voice/research soak passed**. This report does not approve or merge
that gate change.

## Memory v4 Gates

| Gate | Measurement | Result |
| --- | ---: | --- |
| v3 migration | 2 durable + 1 recent retained; reload idempotent | pass |
| Episode/open-loop caps, prune, dedup | unit fixtures | pass |
| Negative open-loop captures | `0/12` | pass |
| Positive open-loop recall | `10/10` | informational `1.00` |
| Distillation invalid-result drops | `9/9`; counter incremented | pass |
| Distillation transport boundary | loopback HTTP only; LAN/public/credential endpoints rejected | pass |
| Relationship-card budget | synthetic worst card `1530/1800` chars | pass |
| One-shot callback | consumed once; absent next prompt/session | pass |
| v3 exact / paraphrase / false | `1.00 / 1.00 / 0.00` | baseline recorded |
| v4 exact / paraphrase / false | `1.00 / 1.00 / 0.00` | pass |
| Relationship-card assembly p95 | `1.1885 ms` (1000 iterations) | pass (`<5 ms`) |
| Gemma prefill p50 delta | `1358.27 - 1434.82 = -76.55 ms` (5 repeats) | pass (`<=500 ms`) |
| Trusted facts | ready, 0 model calls, no audio | pass |
| Research isolation | natural freshness fixture created 0 v4 records | pass |

Probe artifacts: `output/memory-v4-evidence/memory-probe.json` and
`output/memory-v4-evidence/prefill-probe.json`.

The negative prefill delta is run-to-run inference variance, not an optimization claim.

The live callback benchmark initially failed five prompt variants because E2B ignored the card.
The final trusted-context composition passed. Final callback: `1307.73 ms`, mode `speak`, arousal
`0.2`, valence `0.1`, empty `memory_write`. The episode case passed at `1183.14 ms`. Artifacts:
`output/memory-v4-evidence/model-callback-final` and
`output/memory-v4-evidence/model-callbacks-attempt6`.

## Research Gate

The recorded SearXNG JSON contract passes `8` broker tests. The deployment is
`tools/searxng/compose.yaml`; it publishes only `127.0.0.1:8080`, requires an uncommitted session
secret, enables JSON, and applies a three-engine allowlist. `tools/check_local_research.ps1` checks
listener exposure, response format, engine membership, and broker search/fetch.

Live status is pending: no listener exists on port `8080`, and Docker/Podman/WSL installation is
reserved for the owner. No interim direct-engine adapter was enabled.

## Verification

- `python -m unittest discover -s bridge -p "test_*.py"`: `320` passed in `46.366 s`.
- `pio test -e native_logic`: `261/261` passed in `20.652 s`.
- `tools/test_full_system_soak_evidence_contract.ps1`: passed.
- Current-lead reproducibility and archive contracts: passed.
- `trusted_facts_smoke.py` against the live v3 file: ready, zero model invocations, no audio.
- DirectML environment compile/device probe: `AMD Radeon RX 7800 XT`, available.
- Fallback-TTS true/false telemetry contract and all three memory counters were exercised in tests.

## Negative Results

- The first idle ROCm conversion remains `59.58 s`; this task did not optimize that path.
- The Ollama-unloaded P3 cell was not run because it would disturb the active brain.
- The archive has no driver capture, preventing an exact archived-driver comparison.
- Five live callback attempts failed before the final prompt composition passed; artifacts remain.
- Live SearXNG acceptance and the mixed research/voice soak are pending owner container setup.
- Physical-robot Memory v4 behavior remains unmeasured.
