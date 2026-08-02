# 2026-08-02 Read-Only Audit Wave

Audited source: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`
Repository: `RobVanProd/stackchan_alive`
Mode: ten independent read-only Luna roles plus one independent document reviewer

No audit agent edited files, called a mutating robot endpoint, restarted a service, inspected live
memory values, raw audio/camera data, credentials, pairing values, or private evidence. Synthetic
fixtures used aggregate/non-private values. Source reproduction is not physical proof.

## AUDIT-01 — Repository and Branch Truth

### Findings and replay references

- All fetched branch names/SHAs, merge bases, ahead/behind, patch equivalence, and PR states in
  `BRANCH_LEDGER.md` were independently recomputed.
- PR #218 effective PlatformIO config runs the reproducible hook twice for `stackchan_wifi`:
  `platformio.ini:74-75,120,125-127`. PlatformIO 6.1.19 `ProjectConfig` expansion reported two;
  every other candidate environment reported one.
- `tools/platformio_reproducible_build.py:50-55` uses 12-character HEAD plus tracked-dirty state,
  ignores untracked files, and does not hash dirty content.
- Release packaging does not reject/record `STACKCHAN_BUILD_STAMP` or
  `STACKCHAN_DISABLE_REPRODUCIBLE_BUILD`.
- `tools/package_release.ps1:142-155` packages `stackchan`,
  `stackchan_servo_calibration`, and `stackchan_release_full`; all require paired clean hashes.
- The merged companion worktree has tracked modification
  `artifacts/face/phase_e_speech_reactive_6s.gif`; worktree deletion needs full tracked/untracked/
  ignored preservation.

### Commands/results

```text
git for-each-ref refs/heads refs/remotes/origin
git worktree list --porcelain
git merge-base origin/main <ref>
git rev-list --left-right --count origin/main...<ref>
git cherry origin/main <ref>
gh pr list --state all --json ...
gh pr view 218 --json ...
```

All recorded topology/PR claims passed. No firmware/test rerun was part of this role. Files changed:
none. Commit: none. Remaining uncertainty: paired reproducible hashes are not yet durable evidence.

## AUDIT-02 — Conversation and Turn Taking

### Ranked findings and replay references

1. Playback start/chunk/finish failure can omit `playback_complete`:
   `src/io/BridgeAudioDownlink.cpp:34,184,208,222`, `src/main.cpp:7259,9384`. Host defers terminal
   response at `bridge/lan_service.py:3653`, while `bridge/conversation_session.py:355` has no
   `SPEAKING` timeout.
2. Model/TTS recovery changes host state at `bridge/conversation_session.py:311`,
   `bridge/lan_service.py:1722,2618`, but sends error rather than the firmware ReplyWindow path at
   `bridge/lan_service.py:2130`; firmware capture opens only at `src/main.cpp:7207,4947`.
3. Host capture lease defaults to 10 seconds at `bridge/conversation_session.py:22,230`; firmware
   permits 12-second endpoint, 13-second capture, and 15-second privacy guard at
   `src/io/VoiceActivityEndpoint.hpp:21`, `src/main.cpp:987`,
   `src/io/BridgeWakeGate.hpp:14`. A clock-driven probe timed out at 10,001 ms and rejected the
   valid 12,000 ms end.
4. `src/io/BridgeWakeGate.cpp:78,93` uses rollover-unsafe raw time comparisons.

Positive paths for endpointing, matching playback completion, cancellation, silence/exit, and
correction/research continuity are source-tested. Physical echo, barge-in, long turns, latency, and
no-motion soak remain unqualified.

### Commands/results

Forty-two focused host tests across conversation session/harness, model/TTS failure, playback
sequencing, correction, shared-room suppression, and WebSocket cancellation: `42/42` passed.
Inherited baseline: bridge `543/543`, native `289/289`. No native rebuild or hardware. Files changed:
none. Commit: none.

## AUDIT-03 — Memory and Continuity

### Ranked findings and replay references

1. Normalization validates shape but not current-turn authorization:
   `bridge/character_harness.py:584-656,745-755`; runner policy does not clear other valid actions at
   `bridge/ollama_stackchan_runner.py:649-732`; all normalized deltas apply at
   `bridge/reference_bridge.py:160-182` and `bridge/bridge_memory.py:1217-1315`. Synthetic ordinary
   turns accepted an unprompted write and wildcard forget.
2. Third-party filtering is finite/lexical at `bridge/bridge_memory.py:121-128,270-281` and
   `bridge/character_harness.py:219-235,584-601`; a generic synthetic coworker fact passed.
3. Earliest due loop is selected without request relevance at
   `bridge/bridge_memory.py:1578-1597`; `bridge/local_runner.py:361-382` can replace the response.
4. Explicit temporal recall can return newest episode before topic ranking at
   `bridge/bridge_memory.py:551-587`.
5. Distillation checks shape/privacy but not entailment/provenance at
   `bridge/episode_distillation.py:72-121`.
6. Last-write-wins/silent near-duplicate handling lacks supersession at
   `bridge/bridge_memory.py:819-836,1106-1142`.
7. Structurally invalid parseable primary can suppress valid backup at
   `bridge/bridge_memory.py:1688-1714`; sequential reset unlinks at `1739-1744`.

### Commands/results

- 108 focused memory/local-fact/character/runner tests passed.
- 10 initiative-policy tests passed.
- 10 selected LAN persistence/forget/shared-room/persona/episode/callback tests passed.
- `python bridge/memory_probe.py`: exact `1.0`, paraphrase `1.0`, injected-fact `0.0`, relationship
  card p95 about `1.8 ms`; this probe does not traverse ordinary model-action authorization.

No private live values/transcripts were read. No kill/disk/reset fault or longitudinal/physical v4
test ran. Files changed: none. Commit: none.

## AUDIT-04 — Emotion and Self State

### Ranked findings and replay references

1. Semantic dependency policy is narrow regex at `bridge/character_harness.py:321-343,714-720`;
   four synthetic guilt/exclusivity/discourage-human-contact paraphrases passed unchanged.
2. `src/persona/IntentEngine.cpp:20-46` enables demo at boot and `:166-203` injects random synthetic
   affect events every 2.5-6 seconds. Native `test/test_native_logic/test_main.cpp:1400-1420`
   demonstrates demo prevents sleep. Only serial `demo off` at `src/main.cpp:9296-9298` disables it.
3. Streaming clamps device-bound valence to `[0,1]` at `bridge/lan_service.py:2451-2461`, while TTS
   retains signed range at `:2663-2666`; probe `-0.72` produced device `0.0`, TTS `-0.72`.
4. Affect is real mutable uptime state at `src/persona/EmotionModel.hpp:23-75` and
   `EmotionModel.cpp:124-340`, but resets in `IntentEngine::begin()` and lacks durable state.
5. Fieldwise validation at `bridge/character_harness.py:730-788` accepted contradictory safety
   mode, happy speech/earcon, and incompatible affect.

### Commands/results

Native `289/289`; character harness `24/24`; red team `11/11`; reference bridge `14/14`; robot
embodiment `3/3`; RVC TTS `3/3`. Synthetic paraphrase, signed-valence, and cross-field probes
reproduced the gaps. No audio playback/hardware. Current-main affect physical evidence is
unqualified. Files changed: none. Commit: none.

## AUDIT-05 — Perception and World Grounding

### Ranked findings and replay references

1. `CameraAdapter::submitFaceLost()` retains `lastSize` at
   `src/io/CameraAdapter.cpp:311-320`; every lost event refreshes `lastEventMs` at `:356-365`.
   Heartbeat freshness at `src/main.cpp:7442-7443` ignores target validity. Empty detections arrive
   at `bridge/vision_service.py:218-236` / `src/main.cpp:8742-8746`. Host treats the bit as current
   presence at `bridge/lan_service.py:2053-2061` and `bridge/robot_embodiment.py:114-126`.
2. Prompt room context expires at `bridge/room_context.py:417-427`, but `latest_summary()` at
   `429-431` is age-free and failures retain prior state at `389-393`; relationship projection at
   `bridge/lan_service.py:1461-1489` can use stale one-person context.
3. Cached debug can resurrect dashboard connected/operational state:
   `bridge/dashboard_service.py:294-298,351-365,477-550`.
4. Room summaries lack source/confidence/contradiction at `bridge/room_context.py:61-85`; presence
   sources overwrite/double-count at `bridge/lan_service.py:2053-2061,4038-4045` and
   `bridge/initiative_policy.py:12-20,94-99`.
5. Face-worker private-address/redirect handling differs from room transport at
   `bridge/vision_service.py:49-61` and `bridge/room_context.py:185-197`.

### Commands/results

Native `289/289`; relevant Python tests `56/56`; four focused LAN room/initiative tests `4/4`.
Synthetic aggregate probes reproduced sticky freshness, stale room projection, stale dashboard
state, and URL-policy divergence. No frame/live camera/robot/private data. Physical false presence
was not attempted. Files changed: none. Commit: none.

## AUDIT-06 — Initiative and Planning

### Ranked findings and replay references

1. Host checks thermal/power inhibit at `bridge/lan_service.py:2253-2261`, but production heartbeat
   `src/main.cpp:7427-7505` does not transmit those fields. A real-shaped critical-energy/2-percent
   heartbeat remained initiative-eligible; artificially supplied fields blocked.
2. Decision occurs at `bridge/lan_service.py:2222-2274`, then model/TTS at `2276-2362`; only cancel/
   utterance-start cancels at `3890-3898`. Later sleep/safety/presence heartbeat does not revalidate.
3. Initiative uses the same narrow dependency validator; three synthetic guilt/attention-debt
   variants passed.
4. Dashboard toggle at `bridge/dashboard_service.py:435-448` is runtime-only while spoken preference
   persists at `bridge/lan_service.py:2940-2960`; simulated restart restored stored true.
5. `InitiativeDecision` at `bridge/initiative_policy.py:51-55` lacks evidence/confidence/value/
   why-now/privacy/silence/social fields and receives no memory/conversation lines at
   `bridge/lan_service.py:2293-2306`.
6. Freshness flapping and room transition double-counting at
   `bridge/lan_service.py:2050-2061,4038-4045` can manufacture curiosity.

### Commands/results

```text
python -m unittest -v bridge.test_initiative_policy bridge.test_lan_service \
  bridge.test_dashboard_service bridge.test_character_harness bridge.test_character_red_team
```

`164/164` passed. Synthetic heartbeat, flap, double-count, restart, and semantic probes reproduced
the gaps. Physical/longitudinal initiative remains unqualified. Files changed: none. Commit: none.

## AUDIT-07 — Multimodal Expression

### Ranked findings and replay references

1. Active phrase streaming signed-valence loss at `bridge/lan_service.py:2457`; TTS/summary preserve
   signed value at `:2493,2665`. Probe `-0.4` produced wire `0.0` and TTS/summary `-0.4`.
2. Character validator retains earcon at `bridge/character_harness.py:782-789`, but `BridgeTurn` has
   no earcon at `bridge/reference_bridge.py:55-70`; wire omits it. Firmware derives local response
   earcon at `src/main.cpp:7248`, while Wi-Fi streamed playback cancels local speech/earcon at
   `src/main.cpp:9424-9425`.
3. Partial streaming failure closes protocol at `bridge/lan_service.py:2585-2638` but provides no
   coherent spoken/degraded-voice cue.
4. Spark Sleep prompt/audio transcript conflict is at `personas/spark/character.yaml:96` and
   `personas/spark/voice.yaml:105-112` in non-Wi-Fi audio scope.
5. Response gesture targets at `src/persona/IntentEngine.cpp:100,401` are commands, not completion
   evidence.

### Commands/results

All four persona packs passed `tools/verify_persona_pack.py`. Three focused streaming order/failure/
pipelining tests passed. Mocked signed-valence probe reproduced. Inherited native/bridge baselines
pass. No listening, private voice asset, motion, or hardware. Current exact-source expression is
physically unqualified. Files changed: none. Commit: none.

## AUDIT-08 — Product and Onboarding

### Ranked findings and replay references

1. `bridge/dashboard_service.py:561-564` treats presence of `motion_enabled` as verification;
   `bridge/dashboard/app.js:36-58` can call motion safely stopped while rail/torque are true. The
   command path `dashboard_service.py:368-431` remains stronger.
2. Cached debug readiness persists at `dashboard_service.py:343-365,477-550`; UI renders Bridge
   Ready at `bridge/dashboard/app.js:93-111`.
3. Desktop management callbacks default to no-op at
   `companion/.../CompanionConsole.kt:279-304,1664-1729`; desktop `Main.kt:59-131` does not supply
   them and discards many failures through `runCatching`.
4. Launcher/shortcut default to one robot IP at `tools/start_stackchan_dashboard.ps1:2` and
   `tools/install_stackchan_dashboard_shortcut.ps1:2`; runtime prerequisites are fragmented.
5. `bridge/dashboard/app.js:147` renders missing thermal suppression as clear.

### Commands/results

Dashboard tests `20/20` passed. Synthetic integrated-listener refresh and contradictory actuator
snapshots reproduced false readiness/safety. Tracked source was clean during the audit. No UI launch,
install, service, hardware, or private evidence. Files changed: none. Commit: none.

## AUDIT-09 — Privacy, Dependency, and Ethics

This defensive report intentionally omits actionable payloads and network reproduction steps.

### Ranked findings and replay references

1. Production launcher binds all interfaces at `tools/start_pc_brain.ps1:2`; WebSocket admission at
   `bridge/lan_service.py:930` does not enforce existing path/protocol/device/peer/origin signals.
   Protected message dispatch is not admission-conditioned at `bridge/lan_service.py:2036-2120`;
   blank endpoint identity bypasses owner check at `2207-2210`; self-registration occurs at
   `bridge/lan_service.py:495`; serial client service at `4085-4091` creates availability risk.
   Source and synthetic aggregate tests confirmed the boundary.
2. Wi-Fi firmware mutating HTTP classification/handling at `src/main.cpp:8814-8874` includes motion
   publication `:8859-8863`; remote recovery defaults with Wi-Fi at `src/main.cpp:501-502`. Camera
   endpoints have pairing checks at `8684-8689,8731-8740`; mutating control does not. This was not
   exercised on hardware.
3. Sensitive-memory enforcement is lexical/open-ended at `bridge/bridge_memory.py:42-120,270,
   1356-1372` and `bridge/character_harness.py:586-635`.
4. Dependency policy intent at `bridge/character_harness.py:24-32` exceeds runtime semantic coverage
   at `321-344,715-721`.
5. GitHub Actions use mutable refs; Gradle wrapper lacks distribution checksum; Python inputs lack
   artifact hashes. This is source posture, not a demonstrated compromise.

Affected: production PC launcher; `stackchan_release_full` and other Wi-Fi firmware profiles. Default
non-Wi-Fi `stackchan` is not affected by HTTP controls; OTA remains separately token/digest-gated.
No live memory/network/device exploitation occurred. Files changed: none. Commit: none.

## AUDIT-10 — Research and Evaluation

### Ranked findings and replay references

1. `bridge/companion_harness_qualification.py:243-252,337-365` validates 100 IDs but executes top-20
   controls without full ID-to-disposition trace. Independent count: 100 rows, 59 clusters, 20
   controlled clusters, 50 rows/39 clusters outside executable controls.
2. Subjective physical booleans lack anchored trials at
   `bridge/bridge_ai_qualification.py:19-41,744-758` and
   `tools/complete_bridge_ai_supervised_qualification.ps1:5-25,91-117`.
3. Research acceptance validates URL/excerpt/transport, not factual support at
   `bridge/research_acceptance.py:16-29`, `bridge/research_broker.py:387-406`, and
   `bridge/bridge_ai_qualification.py:542-553`.
4. Memory probe fixture at `bridge/fixtures/memory_probe.json:36-85` and
   `bridge/memory_probe.py:42-64,96-111` is small lexical routing; v3/v4 both score `1.0`.
5. Three-turn latency and two-opener initiative gates are engineering health evidence, not
   longitudinal experience distributions: `bridge/conversation_latency_report.py:22-80`,
   `bridge/bridge_ai_qualification.py:645-713`.

### Commands/results

- `python bridge/companion_harness_qualification.py --run`: 32 tests, 20/20 controls, 100 IDs.
- Research/latency/memory focused suite: `16/16` passed.
- `python bridge/memory_probe.py`: all current gates passed; v4 retrieval same as v3.

Ten primary research mechanisms, limitations, and falsifiable predictions are in
`RESEARCH_LEDGER.md`. No human/physical study ran. Files changed: none. Commit: none.

## Independent Document Review

VERIFY-DOC-01 checked mandate fields, source identity, branch facts, physical-evidence language,
architecture authority, cross-document consistency, primary research identities, Markdown shape,
and replayability. It initially rejected the documents as preregistration basis. Corrections are
tracked in `TASK_LEDGER.md` and include durable audit evidence (this file), single memory
authorization semantics, silence comparison, explicit body/social/clock ownership, operational
scorecard formulas, stop-ship security tasks, and current containment state. A second independent
review is required after status-document reconciliation and SEC-001 preregistration.

VERIFY-DOC-02 then rejected four concrete cross-document contradictions: private paired evidence
was attributed to public v0.2, the presence acceptance test inverted the desired outcome,
`SAFE-001` still competed with the selected stop-ship slice, and reconciled documentation remained
listed as an open fault. It also required exact SEC-001 fixture/version/seed/trial/artifact fields.
Those defects were corrected without source edits. The same independent reviewer repeated the
read-only pass and returned **ACCEPT**: the Milestone 0 control baseline and frozen SEC-001
preregistration are internally consistent. No source implementation was reviewed.
