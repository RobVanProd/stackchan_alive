# Branch Ledger

Audit timestamp: 2026-08-05 America/New_York

## Active Qualification Routing (2026-08-05)

- **Sole M0/P0 qualification worktree:**
  `D:\CodexProjects\stackchan_alive\output\worktrees\aliveness-repository-truth` on
  `codex/aliveness-repository-truth`. Verify its exact head and clean state before every
  qualification command, and require it to match `origin/codex/aliveness-repository-truth`. Do not
  hard-code the qualification-tooling head: it advances when reviewed evidence tooling is committed.
  The currently installed firmware and running host were both launched from source checkpoint
  `a0f56b76f0bece2f4f732f70d3115bc6800c843d`; that installed-source identity is distinct from the
  recorder/checker source identity. No other retained worktree is a qualification input.
- **The primary checkout is not a qualification host.** As of this audit it is clean `main` at
  `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`; use it only as the current default source checkout.
- **`agent/away-cloudflare-bridge` is quarantined, not merely paused.** Preserve it unchanged at
  `269b11beeac788f76fff5d566446a91b8688bf8f`. It predates SEC-001/SEC-002, ships
  `data/cert/x509_crt_bundle.bin`, and changes `src/main.cpp`,
  `BridgeWiFiProvisioningStore`, and other bridge/network authority paths. Do not merge, rebase,
  package, flash, or qualify it because CI is green or the feature diff appears self-contained.
  Its release-full profile explicitly restores motion and autonomous motion at boot; its remote
  path also predates current pairing/admission and `emergency_stop_only` enforcement. Most of the
  unsafe lane would merge without a textual conflict, so mergeability is not containment evidence.
  Remote-access approval must first be explicitly opened. Any future implementation must be built
  afresh from the then-current qualification head and independently reviewed against
  `emergency_stop_only`, pairing/credential boundaries, privacy, protocol ownership, and
  motion/rail/torque containment.

This section is the current routing authority. The original 2026-08-02 checkout and local-`main`
observations below remain historical audit evidence, not current operating instructions.

## Audit Basis

- Repository: `RobVanProd/stackchan_alive`
- Fetched baseline: `origin/main` at
  `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec`
- Baseline commit date: `2026-07-31T01:45:18-04:00`
- Baseline subject: `Harden companion bridge against top conversational pain points (#219)`
- Working branch: `codex/aliveness-repository-truth`, created directly from the fetched baseline.
- The pre-existing checkout was not switched because it is used by live bridge/vision/voice
  services. Its branch is `agent/away-cloudflare-bridge` at `269b11be`.
- Local `main` is at `36acc0c7`, 75 commits behind fetched `origin/main`. It is not the audit
  baseline.
- Ahead/behind below means branch-unique/main-unique commits from
  `git rev-list --left-right --count origin/main...<branch>`.
- Patch equivalence was checked with `git cherry origin/main <branch>`; a `-` result means the
  change is already represented on `main` even when topology is not merged.
- PR state came from the connected GitHub repository and `gh`. No branch was merged, rebased,
  pushed, closed, deleted, or force-updated during this audit.

`gh-pages` at `49cefe092920c0a12da50896356394d380df6904` is generated publication output and is
intentionally excluded from source-branch disposition.

## Source And Feature Branches

Scope records whether the fetched ref exists locally, remotely, or in both places. A missing remote
upstream is not evidence that an attached local worktree is disposable.

| Branch | Scope | Merge base | Ahead / behind | Unique files and mechanism | Existing PR | Security implications | Disposition |
| --- | --- | --- | ---: | --- | --- | --- | --- |
| `agent/away-cloudflare-bridge` | Local + remote | `36acc0c735132f06dae5d31e5a2cb145db1258b8` | 1 / 75 | 35 files across firmware endpoint/network/provisioning code, Android/desktop endpoint services, `deploy/cloudflare`, a CA bundle, and `docs/AWAY_CLOUDFLARE_BRIDGE.md`; adds Cloudflare-backed Away routing. | None | **High.** Re-enables release-full motion/autonomous motion at boot, retains pre-SEC-002 unsafe HTTP routes, accepts replayable persistent profile changes without active-owner/freshness checks, terminates the tunnel at a pre-SEC-001 Kotlin server, and stores Wi-Fi/Access credentials as plaintext JSON. | **Archive/quarantine.** Preserve the exact branch as research evidence; do not merge, rebase, or cherry-pick it. No changed file is approved for whole-file salvage. Any future remote-access lane must be implemented afresh from the then-current qualification head after explicit approval and the review gate above. |
| `codex/native-release-guard-fixture` | Local only | `39b750e6c354d1c4721c70bf20fba98b8ce5c3ec` | 21 / 0 | Fixture-only `ReadDirectoryChangesExW` mutation barrier, native P/Invoke source, and adversarial contracts. Production callers remain on `FileSystemWatcher`. | None | Changes the exact release-policy helper bytes and therefore invalidates current bootstrap/allowlist pins. It does not yet cover transient source-root injection, exact build-Job accounting, or root-object ACL/attribute changes. | **Preserve as future hardening; not an M0 input.** Local commit `c8d6be2ef7c8aaa2a4ac3475ac879e369db44763` intentionally remains unpushed and non-promotion-ready. Do not merge until line-ending authority, helper/allowlist/bootstrap pins, missing containment controls, full contracts, and an independent guarded build all pass together. |
| `agent/companion-complaints-harness` | Local only; upstream gone | `81147d8e73f861543d7b0813991b2db6674c0301` | 1 / 1 | Host bridge complaint corpus, qualification harness, memory/persona/initiative/failure-recovery hardening, and tests. Its tree is identical to fetched `origin/main`; `git cherry` reports the commit patch-equivalent. | [#219](https://github.com/RobVanProd/stackchan_alive/pull/219), merged | Privacy and relationship-safety controls are material, but the reviewed content is already on `main`. The local worktree runs production voice/bridge support processes. | **Delete only after retirement and preservation review.** Code is merged, but the worktree currently has a tracked modification to `artifacts/face/phase_e_speech_reactive_6s.gif`. Retain it until services are deliberately migrated or stopped, then inventory and preserve all tracked, untracked, and ignored user/runtime data before deleting the redundant branch/worktree. |
| `codex/release-integration-preview` | Local only | `329b50c989ed08e582c8f361b903bce9d1a39196` | 3 / 196 | Release archive tooling, private/public evidence distinctions, reproducibility checker changes, package verifier changes, and contracts. All three commits are patch-equivalent to `main`. | None | Release credential hygiene and private diagnostic/public-package separation are security-critical. Those mechanisms are already on `main`. | **Delete after worktree retirement.** No unique patch remains. Preserve tracked, untracked, and ignored release evidence before removing its worktree. |
| `codex/release-tooling-final` | Local only | `e6b80f32abcb71a61e1eb8616702e216c33ed3cd` | 2 / 209 | Earlier form of the same release archive and private/public evidence tooling. Both commits are patch-equivalent to `main`. | None | Same release-secret and artifact-integrity boundaries as above; already represented on `main`. | **Delete after worktree retirement.** Superseded and patch-equivalent; inventory tracked, untracked, and ignored evidence first. |
| `claude/interactive-features-roadmap-mmj5u4` | Remote only | `b6f95de495a4c349eb5f452232a6112d82cd8b03` | 1 / 160 | Adds only `docs/NEXT_HORIZON.md`, a post-release feature analysis. | None | No runtime authority change, but stale capability/status claims could misdirect hardware or privacy work. | **Selectively salvage, then archive.** Review individual research/gap claims against current `main`; move only still-valid items into the task/research ledgers. Never merge the stale roadmap wholesale. |
| `feature/arrival-sim-baseline` | Remote only | `2df609809ecb8aae19e21bc20741044bc493aeb3` | 1 / 408 | Arrival simulation/preflight and evidence-document changes. The commit is patch-equivalent to `main`. | [#66](https://github.com/RobVanProd/stackchan_alive/pull/66), merged | Evidence-gate semantics can affect promotion conclusions, but the reviewed patch is already on `main`. | **Delete.** Merged and patch-equivalent; remote branch is redundant. |
| `feature/conversation-audio-loop-sim` | Remote only | `dcc57d03512da2d44fbf1f6b3fc852b21fcf7029` | 1 / 409 | Hardware simulator audio-loop behavior, tests, docs, and package verification. The commit is patch-equivalent to `main`. | [#65](https://github.com/RobVanProd/stackchan_alive/pull/65), merged | Simulator evidence must not be mistaken for physical proof, but the mechanism is already on `main`. | **Delete.** Merged and patch-equivalent; remote branch is redundant. |
| `fix/reproducible-firmware-builds` | Remote only | `10b0cc5404e072bb5784d9cfd2fabb0babd8a02e` | 2 / 67 | Adds `tools/platformio_reproducible_build.py`, attaches it to firmware environments in `platformio.ini`, documents the invariant in `AGENTS.md`, and includes an unrelated LAN test bind-wait change. | [#218](https://github.com/RobVanProd/stackchan_alive/pull/218), open, conflicting | Build stamps affect exact-image provenance. The environment override can intentionally vary the stamp; coverage gaps could silently leave a release-capable environment nondeterministic. The LAN test change should not ride along without current need. | **Selectively salvage onto current `main`.** Preserve the deterministic build-stamp mechanism only after current review, add a contract covering every release-capable firmware environment, and re-run clean double builds. Do not merge or rebase the stale two-commit branch wholesale. |

The detached clean worktree `output/worktrees/release-20bd392d` is at `20bd392d`, whose commit is
already contained in `origin/main` and is six commits behind it. It is not a branch disposition,
but it must remain inventoried until the associated release worktree is deliberately retired.

## Dependency Compatibility Domains

All dependency branches share merge base
`36acc0c735132f06dae5d31e5a2cb145db1258b8`, are 1 commit ahead and 75 commits behind
fetched `origin/main`, and have open non-draft PRs. Treat each compatibility domain as one change;
do not merge individual majors merely because GitHub reports them mergeable.

| Compatibility domain | Branches and PRs | Unique files and mechanism | Security / compatibility implications | Disposition |
| --- | --- | --- | --- | --- |
| Pages publication stack | `dependabot/github_actions/actions/configure-pages-6` ([#202](https://github.com/RobVanProd/stackchan_alive/pull/202)); `dependabot/github_actions/actions/deploy-pages-5` ([#200](https://github.com/RobVanProd/stackchan_alive/pull/200)); `dependabot/github_actions/actions/upload-pages-artifact-5` ([#203](https://github.com/RobVanProd/stackchan_alive/pull/203)) | Major-version changes in `.github/workflows/pages.yml`. | Workflow supply chain, token permissions, artifact format, and Pages deployment compatibility must be reviewed together. | **Rebase as one coordinated group** after verifying official action migration notes, pinned provenance policy, least-privilege permissions, and a successful Pages rehearsal. Otherwise archive and let Dependabot regenerate. |
| Release artifact transport | `dependabot/github_actions/actions/download-artifact-8` ([#201](https://github.com/RobVanProd/stackchan_alive/pull/201)) | Major-version change in `.github/workflows/firmware.yml` and `.github/workflows/release.yml`. | Affects the exact artifacts later packaged or released; path/merge behavior changes could invalidate release evidence. | **Rebase independently only with artifact-contract tests** and a workflow rehearsal. Archive/recreate if upstream migration cannot preserve exact artifact identity. |
| CI Python runtime | `dependabot/github_actions/actions/setup-python-7` ([#209](https://github.com/RobVanProd/stackchan_alive/pull/209)) | Major-version change in firmware and release workflows. | Changes toolchain acquisition and caching used by release gates; provenance and Python-version resolution matter. | **Rebase with the CI toolchain domain**, then run all workflow-equivalent release gates. Do not combine with runtime Python package majors. |
| Vision/scientific ABI | `dependabot/pip/numpy-2.5.1` ([#204](https://github.com/RobVanProd/stackchan_alive/pull/204)); `dependabot/pip/opencv-python-headless-5.0.0.93` ([#208](https://github.com/RobVanProd/stackchan_alive/pull/208)) | Changes `bridge/requirements-vision.txt`; NumPy also changes `tools/voice_v2_directml_constraints.txt`. | Major NumPy/OpenCV ABI and API changes can break the pinned vision environment and DirectML/RVC tooling. | **Rebase and test as one compatibility group** in fresh pinned environments with vision fixtures, camera-auth boundaries, and voice setup. Selectively salvage version constraints only after compatibility is proven. |
| DirectML PyTorch family | `dependabot/pip/torch-2.13.0` ([#206](https://github.com/RobVanProd/stackchan_alive/pull/206)); `dependabot/pip/torchaudio-2.11.0` ([#207](https://github.com/RobVanProd/stackchan_alive/pull/207)); `dependabot/pip/torchvision-0.28.0` ([#205](https://github.com/RobVanProd/stackchan_alive/pull/205)) | Independent edits to `tools/voice_v2_directml_constraints.txt`. | These packages are a coupled binary family. Independently selected versions may be incompatible with each other, Python, DirectML, or the accepted RVC worker. Voice-model execution and private model handling must remain local and unchanged. | **Archive the independent branches and regenerate a tested lockstep update.** Do not rebase or merge them separately. Require clean environment setup, worker health, deterministic voice tests, and supervised audio evidence before promotion. |

## Reproducible-Build Candidate Review Gate

PR #218 correctly identifies a concrete nondeterminism source: Arduino core diagnostic output embeds
`__DATE__` and `__TIME__`, which changes the ELF and derived firmware hash. Its proposed pre-build
script derives deterministic macro values from the 12-character `HEAD` identity plus a
tracked-dirty marker; it deliberately ignores untracked files and does not hash tracked dirty
contents. It attaches the script explicitly because PlatformIO environment `extra_scripts`
values override rather than merge.

The candidate is not merge-ready:

- GitHub reports the PR conflicting and its head is 67 commits behind current `main`.
- The mandate requires a contract proving that every release-capable firmware environment
  participates; the PR explicitly does not contain that contract.
- Effective PlatformIO 6.1.19 expansion runs the hook twice for `stackchan_wifi`: the environment
  inherits it from `env:stackchan` and also adds it directly. Every other candidate environment
  has one effective hook. Salvage must establish an exactly-once contract.
- `STACKCHAN_BUILD_STAMP` and `STACKCHAN_DISABLE_REPRODUCIBLE_BUILD` are not sanitized, rejected,
  or recorded by `package_release.ps1`, so packaging can silently vary or disable the mechanism.
- The second commit changes a LAN-service test bind race and is semantically unrelated to firmware
  reproducibility.
- A direct invocation through the default shared PlatformIO core failed before source compilation
  because that core resolved no Arduino framework directory. The documented isolated pioarduino
  core at `C:\spio\pioarduino` then built the same current-main environment successfully. This is
  an execution-context defect in the baseline command/path, not a source-compilation regression;
  reproducibility tests must pin and report the intended core.

Required salvage experiment:

1. Pin the documented pioarduino core in the test invocation and add a preflight that distinguishes
   a missing framework package from a source build failure without weakening package pinning.
2. Port only the deterministic build-stamp mechanism to current `main`.
3. Add an effective-configuration contract that fails unless every firmware-producing or
   release-capable PlatformIO environment has exactly one reproducible-build pre-script.
4. Build all three public packaged environments -- `stackchan`,
   `stackchan_servo_calibration`, and `stackchan_release_full` -- plus each private
   evidence-bearing camera/forensics domain twice from clean build directories across a
   wall-clock boundary and compare exact firmware SHA-256.
5. Sanitize or reject custom stamp input, and make release packaging reject or durably record
   both the override and disable controls. Neither may silently affect a release package.

## Recorded Baseline Gates

| Gate | Result |
| --- | --- |
| `pio test -e native_logic` | **Pass:** 289/289 |
| `python -m unittest discover -s bridge -p "test_*.py"` | **Pass:** 543/543 |
| `python bridge/trusted_facts_smoke.py --memory-file <private current memory> --json` | **Pass:** `ready=true`, `modelInvocations=0`, `audioPlayed=false`, no stored fact values printed |
| `pio run -e stackchan_release_full` through the default shared core | **Execution-context fail before source compilation:** pioarduino builder received `FRAMEWORK_DIR=None`, raising `TypeError` while constructing `pioarduino-build.py` |
| Same environment with documented `PLATFORMIO_CORE_DIR=C:\spio\pioarduino` | **Pass:** 2,803,216-byte secret-free firmware, baseline SHA-256 `8A76CA8030B3CD0C06C76C2A869C42B960E6864E7C5D7CC6A339E918FB1BB756` |
| `tools/test_full_system_soak_evidence_contract.ps1` | **Pass** |
| `tools/test_current_lead_reproducibility_contract.ps1` | **Pass** |
| `tools/test_archive_current_lead_contract.ps1` | **Pass** |

No firmware was flashed, no robot endpoint was called, no motion command was issued, and no running
service was restarted or terminated during this audit.
