# Project State

State timestamp: 2026-08-02 America/New_York

## Current Objective

Complete Milestone 0 repository/document truth and contain the newly confirmed LAN trust-boundary
failure before any aliveness feature work. All ten read-only audits are complete. The current work
is documentation, preregistration, and test-first security repair; no robot behavior change has
been implemented.

## Source Identity

- Repository: `RobVanProd/stackchan_alive`
- Working branch: `codex/aliveness-repository-truth`
- Working commit: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`
- Fetched `origin/main`: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`
- Last source-verified commit: `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`
- Verification scope: native firmware logic, host bridge tests, silent trusted-facts routing,
  secret-free release compilation through the documented isolated pioarduino core, and three
  release/evidence contract suites.
- Physical verification is not transferred to this host/documentation commit.

The pre-existing checkout remains on `agent/away-cloudflare-bridge` at `269b11be`. It was not
switched because live services use that checkout. Milestone 0 work uses the isolated worktree at
`output/worktrees/aliveness-repository-truth`.

## Active Hypothesis

Selected candidate: `SEC-001`, fail-closed PC bridge admission using signals already emitted by
firmware and configuration already supplied to the production launcher.

- **Observed behavior:** A non-loopback bridge bind does not enforce exact path, firmware protocol/
  device headers, configured robot peer, or browser-origin rejection; connection dispatch is not
  conditioned on a validated HTTP upgrade, and blank endpoint identity bypasses an active owner.
- **Primary hypothesis:** Enforcing those existing admission signals at the HTTP upgrade and
  rejecting protected messages on an explicitly unadmitted session will reduce accepted untrusted
  protected operations to zero while the valid firmware-shaped connect/server-hello/reconnect path
  remains compatible.
- **Falsification:** A current firmware client lacks a required stable signal; any wrong-peer/
  origin/path/header/pre-admission case performs a protected operation; the valid case fails; or
  the change requires a client-side hello, pairing secret, or new identity protocol.
- **Frozen baseline:** Exact source `39b750e6`, contained bridge, untouched firmware/robot, live
  voice/vision workers, current message schemas, memory/STT/model/TTS/dashboard behavior.
- **Rollback:** Revert the atomic source/test commit and keep the non-loopback bridge stopped. Do
  not restore the insecure listener as an automatic fallback.

The reproducible-build and memory-authorization hypotheses remain queued P0 work; stop-ship
transport/control containment takes precedence without reordering the later aliveness milestones.

## SEC-001 Frozen Preregistration

This preregistration was reviewed read-only against exact source `39b750e6` before any source or
launcher implementation. Firmware sends no application-side client hello. Admission therefore
completes at the bounded HTTP upgrade, and `X-Stackchan-Device` is never treated as a brain-owner
endpoint or cryptographic identity.

Expected failing tests on the frozen baseline, to be added and demonstrated red before repair:

- `test_admission_rejects_non_bridge_path`
- `test_admission_rejects_missing_or_wrong_protocol`
- `test_admission_rejects_blank_or_invalid_device`
- `test_admission_rejects_browser_origin`
- `test_non_loopback_config_requires_robot_peer`
- `test_admission_rejects_wrong_peer_before_dispatch`
- `test_unadmitted_session_rejects_protected_message`
- `test_owner_gate_rejects_blank_endpoint_when_owner_exists`
- `test_invalid_attempt_does_not_consume_once_recovery`

Compatibility tests that must remain or become green without firmware changes:

- `test_admission_accepts_exact_firmware_upgrade`
- `test_loopback_default_allows_firmware_without_configured_peer`
- `test_valid_firmware_disconnect_and_reconnect_receives_hello`
- existing WebSocket handshake, streaming, cancellation, bridge, native firmware, silent trusted-
  facts, DirectML launcher, and dashboard launcher contracts.

The raw valid fixture is exactly `GET /bridge HTTP/1.1`, WebSocket upgrade/version/key fields,
`X-Stackchan-Protocol: stackchan.bridge.v1`, one normalized nonblank device value of at most 64
characters, and no `Origin`. Security-critical duplicate headers fail closed. A non-loopback bind
requires `RobotHost`; it is resolved once before accept, and the normalized frozen address set is
checked before reading or dispatching a request. Invalid attempts close before `101` and do not
consume `--once`; a later valid firmware connection receives the existing immediate server hello.
The general launcher becomes loopback-default, while the production DirectML launcher opts into
`0.0.0.0` only with its already required robot host.

Frozen implementation files are `bridge/lan_service.py`, `bridge/test_lan_service.py`,
`tools/start_pc_brain.ps1`, `tools/start_pc_brain_directml.ps1`,
`tools/test_start_pc_brain_directml_contract.ps1`,
`tools/test_stackchan_dashboard_launcher_contract.ps1`, and `docs/BRIDGE_PROTOCOL.md`. Rollback is
reversion of the single atomic host-side commit while keeping the non-loopback service stopped.
Stop on any valid-firmware incompatibility, post-admission output change, need for private data or
new wire semantics, unfrozen DNS behavior, hardware access, or live-service restart.

Preregistration metric fields:

- **Fixture:** `bridge/test_lan_service.py::firmware_upgrade_request`, version
  `sec001-firmware-upgrade-v1`, traced byte-for-byte to
  `src/io/BridgeWebSocketTransport.cpp::buildHandshakeRequest`; only synthetic device IDs.
- **Baseline/version:** exact source `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`; the nine named
  rejection tests above are expected to fail for the recorded reasons, while the raw current
  firmware request shape is source-observed.
- **Seed:** not applicable; the validator, peer matrix, and socket sequences are deterministic.
- **Trials:** one execution per named matrix row in the focused red run; after repair, one complete
  focused module run, one complete bridge discovery run, one native logic run, and one run of each
  named launcher contract. Any failure stops the slice rather than being averaged.
- **Artifacts:** ignored, synthetic-only logs under `output/private/sec-001/` named
  `prereg-red.txt`, `focused-green.txt`, `bridge-green.txt`, `native-green.txt`, and
  `launcher-green.txt`; no live/private values, packets, audio, camera data, or credentials.

## Physical Firmware Identity

- Current installed firmware SHA-256: **unknown from live evidence at this audit timestamp**.
- Latest accepted exact-image record in the authoritative deployment documents: source commit
  `ce66f8a0fadfadbc07eb59124522267ba66ee70a`, firmware SHA-256
  `69d3db27f2d7197799fdc08ff3c1dc4d6e3011724fe29899367dc016e48ebfa8`, with a formally checked
  28,807-second all-feature actuator soak.
- That documented hash is historical accepted evidence, not a claim about what is currently
  reachable or installed. Direct `/debug` was unavailable during the current snapshot, so no
  live hash binding is asserted.

## Active Bridge Source And Services

Initial observed Windows processes, before the explicitly authorized security containment:

- PC bridge/dashboard: PID `14648`, launched 2026-07-31 00:12 local, running relative
  `bridge/lan_service.py` from the pre-existing checkout with Gemma, Whisper, DirectML RVC,
  Conversation v2, episode distillation, initiative, room observation, and loopback dashboard
  flags. Because the command uses a relative script path, the exact loaded source commit is not
  proven by process metadata; the checkout currently points at `269b11be` based on local-main
  commit `36acc0c7`.
- DirectML RVC worker process pair: PIDs `36132` and `26576`, explicit source/model paths under
  `output/worktrees/natural-research-voice`; loopback health at port `5059` reports
  `ready=true`, schema `stackchan.rvc-directml-worker.health.v1`, no last error.
- Vision service process pair: PIDs `45004` and `22668`, local paired-camera worker targeting
  `192.168.1.238:8789` with a private pairing-code file. No pairing value was read or printed.
- No PlatformIO, qualification, motion-refresh, or soak runner was found in the process scan.

Containment update on 2026-08-02:

- AUDIT-09 confirmed that the PC bridge's production launcher binds on all interfaces while its
  WebSocket admission and pre-hello sensitive-message boundary are fail-open.
- With user authorization, PID `14648` was stopped only after a final check found zero established
  clients and only its `0.0.0.0:8765` and `127.0.0.1:8766` listeners. Both listeners closed.
- Two user-started replacement `lan_service.py` processes (`42344` and `47448`) exited without
  acquiring the LAN listener. No bridge process currently owns ports `8765`/`8766` on all
  interfaces.
- An unrelated older Python process, PID `27748`, listens only on loopback `127.0.0.1:8765`; it was
  not changed. Voice and vision workers remain running and untouched.
- The user powered the robot, but bounded `/debug` and TCP `8789` checks still did not establish
  reachability. The robot was not rebooted, flashed, moved, or sent a control request.

## Current Live-State Evidence

Bounded read-only snapshot on 2026-08-02:

- Robot `/debug`: three five-second attempts failed with `WebException`.
- Ping and TCP port `8789`: failed in the bounded probe.
- Bridge PID `14648`: listeners exist on `0.0.0.0:8765` and `127.0.0.1:8766`; no established
  robot TCP connection was present.
- Dashboard: reachable on loopback and reports bridge uptime about 231,001 seconds, model/STT/
  voice/playback health, but also reports `robot.connected=true`, `networkState=connected`, and
  `bridgeState=ready` from a last heartbeat approximately 64,909 seconds old.
- Dashboard last-known actuator state is motion off, rail off, torque off, with last reason
  `manual_stop`. This is stale last-known state, not current device proof.
- Room observation is enabled but stale, with `camera_unavailable` as its last aggregate error;
  initiative reports stale presence and zero curiosity score.

The stale dashboard snapshot above was captured before containment. Its service is now stopped; it
remains evidence of the presentation defect rather than current status.

Observed conclusion: robot reachability is not established, and the dashboard is not expiring its
connected/ready presentation when heartbeat/socket evidence becomes stale. Do not relabel this as
a robot freeze, blackout, brownout, thermal event, USB failure, board failure, or power failure.

## Known Faults

1. The production PC bridge launcher exposes a fail-open robot-to-host WebSocket admission boundary
   on the LAN. Path/protocol/device/peer/origin signals are not enforced, protected message
   families are accepted before trusted admission, and a blank endpoint ID bypasses owner checks.
2. Wi-Fi-enabled firmware HTTP mutating controls are not protected by the existing camera pairing
   gate; source shows motion-resume/recovery/reboot-class requests can reach their handlers. This
   was not exercised on hardware. OTA remains separately token-gated.
3. Dashboard connection/readiness state can remain affirmative after the heartbeat is stale and
   the bridge has no established robot socket.
4. The exact AGENTS baseline command through the default shared PlatformIO core fails before
   source compilation because the pioarduino framework directory is absent. The same environment
   builds successfully when the documented `C:\spio\pioarduino` core is pinned.
5. Ordinary valid model output can currently authorize an unprompted durable write or wildcard
   forget; generic third-party private details can evade the finite sensitive-name filter.
6. A due callback can displace an unrelated user request, and explicit topic recall can choose the
   newest unrelated episode.
7. Playback failure can strand host Conversation v2 in `SPEAKING`; model/TTS recovery can disagree
   with the firmware wake gate; and the 10-second host lease is shorter than the allowed 12-second
   firmware utterance.
8. Release firmware initializes synthetic demo affect events enabled; phrase streaming clamps
   signed negative valence to zero; semantic manipulation paraphrases bypass the current lexical
   relationship validator.
9. Repeated face-lost updates can retain a historical face size while refreshing its timestamp,
   causing a false-current presence bit; stale room state can still permit personal projection.
10. Initiative power/thermal suppression fields are not present in the production heartbeat, and
   an in-flight initiative is not revalidated on a later sleep/safety/presence transition.

Documentation baseline status: required project-control/longitudinal documents and reconciled
status claims now exist in the isolated worktree and passed the final independent review. They
remain uncommitted pending the atomic Milestone 0 documentation commit; this is workflow state, not
an unresolved runtime fault.

## Known Regressions

No repository behavior has been changed by this workstream. Operationally, stopping the exposed PC
bridge intentionally removed LAN brain/dashboard availability; this is a recorded security
containment, not a hidden regression. Voice/vision workers and robot firmware were not changed. The
faults above are reproduced current-source defects or contract gaps, not new physical-event or
hardware-cause attributions. Physical affect, perception, initiative, Conversation v2,
over-speaker barge-in, echo rejection, and a current exact-image no-motion conversation soak remain
unqualified rather than failed.

## Baseline Evidence

- Native logic: 289/289 passed.
- Bridge suite: 543/543 passed.
- Trusted-facts smoke: ready, 19 routed cases, 10 passthrough cases, zero model calls, zero audio,
  no stored fact values printed.
- `stackchan_release_full`: passed under the documented isolated pioarduino core; output size
  2,803,216 bytes, SHA-256
  `8A76CA8030B3CD0C06C76C2A869C42B960E6864E7C5D7CC6A339E918FB1BB756`.
- Full-system-soak evidence contract: passed.
- Current-lead reproducibility v2 contract: passed.
- Current-lead archive contract: passed.
- Branch/PR evidence: `BRANCH_LEDGER.md`.

## Exact Next Action

Commit the independently accepted, evidence-preserving Milestone 0 documentation slice. Then
implement the preregistered smallest fail-closed host admission slice:
validate the existing firmware path/protocol/device signals at HTTP upgrade, reject browser Origin,
require and freeze the configured robot peer for non-loopback binds, allow invalid-then-valid
recovery, and reject protected dispatch on explicitly unadmitted sessions. Firmware sends no
client-side hello; preserve the immediate server hello and do not reinterpret the device header as
brain-owner identity. This is admission hardening, not cryptographic authentication; the separate
firmware mutating-control risk remains contained/unqualified work.

## Unauthorized Actions

- No firmware flash, OTA, reboot, recovery, wake reset, serial command, robot endpoint write,
  motion resume, motion refresh, or actuator test.
- No restart or replacement of the contained PC bridge until the selected admission repair passes;
  voice, vision, model, and the unrelated loopback service remain frozen. The one bridge
  termination above was explicitly authorized after the stop-ship finding and is now recorded.
- No release publication, tag, push, PR mutation, branch deletion, force-push, or evidence deletion.
- No remote/Away infrastructure, credential, pairing, privacy-policy, sensitive-memory,
  identity-recognition, always-listening, cloud-required, or model-physical-authority work.
- No human study, paid service, destructive hardware action, or cross-repository modification.

## Rollback Path

Current file changes are Markdown control records on an isolated branch. The exposed host listener
was stopped; it can be restored by the existing launcher, but must not be restarted until the
admission repair is verified or the user explicitly accepts the known risk. Before implementation,
freeze an atomic source/test scope whose revert removes only that experiment. Hardware rollback
remains the exact private accepted archive and runbook procedure; it is not exercised without the
required source, build, no-motion, physical, and exact-image gates.
