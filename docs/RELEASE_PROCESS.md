# Release Process

This project can produce a pre-device review release now and a hardware-validated release later.

## Local Package

```powershell
.\tools\package_release.cmd -Version <version>
```

The package is written under `output/release/<version>/` and includes firmware binaries, preview media, an expression QA sheet, a root `QUICKSTART.md`, readiness docs, generated readiness reports, the active persona pack under `personas/spark`, `persona_pack_status.json`, voice-source provenance template, companion C6 brain-supervision evidence under `companion/evidence/`, dependency provenance, a machine-readable dependency lock, a dependency audit, copied build inputs, flash helpers, promotion verifiers, a manifest that names the readiness/media/voice/persona/companion evidence artifacts, and SHA256 checksums.
The package command refuses a dirty source worktree by default so code and configuration match the manifest commit. Regenerated preview media is treated as a release artifact.
Release packages also include flash, evidence-capture, and package-verification helper scripts under `tools/`. Use `tools/flash_release_firmware.cmd` to flash the exact binaries from a verified ZIP instead of rebuilding during arrival-day testing.
For the companion C8 distribution path, run `tools/export_companion_release_evidence.cmd`
after Android APK or desktop package artifacts are built. It writes
`COMPANION_RELEASE_EVIDENCE.json/md` with artifact SHA256s, git commit,
`companion/gradle/libs.versions.toml` toolchain pins, and Android release APK signing
status from `apksigner`; use `-RequireArtifacts` when the signed release APK and desktop
packages are required for promotion.

Before flashing or publishing, run the no-hardware preflight:

```powershell
.\tools\run_device_preflight.cmd
```

The preflight also checks that servo-calibration flashing is blocked unless `-ConfirmServoRisk` is present, that dry-run upload commands render correctly, that speech-envelope sidecars can be generated and dry-streamed into serial mouth commands, that the no-hardware virtual Stackchan bridge proxy passes, and that a verified local share can be captured into an evidence packet without requiring a Cloudflare `PUBLIC_URL.txt`.

Run the simulator by itself when you want a fast proxy for bridge behavior while the physical device is unavailable:

```powershell
.\tools\run_hardware_simulation.cmd
```

This proves bridge frame ordering, LAN text turns, binary TTS audio stream accounting, mouth-envelope handoff, and timeout failure behavior. It does not replace real hardware evidence.
If the native logic test step reports missing `gcc`/`g++`, run `.\tools\check_native_toolchain.cmd` to see the searched compiler paths and Windows install options.

Verify the package before sharing it:

```powershell
.\tools\verify_release_package.cmd -Version <version> -ZipPath output\release\stackchan_alive_<version>.zip
.\tools\run_device_preflight.cmd -PackageZip output\release\stackchan_alive_<version>.zip
```

Voice review samples are verified as part of the package gate. To check only the generated Stackchan Spark Synth WAVs and notes:

```powershell
.\tools\verify_voice_samples.cmd
```

To open the local MP3 audition page without starting a share server:

```powershell
.\tools\open_voice_audition.cmd
```

To open the checked-in RVC MP3 audition page:

```powershell
.\tools\open_voice_audition.cmd -Rvc
```

To open one combined local page with both Stackchan Spark and checked-in RVC MP3 audition samples:

```powershell
.\tools\open_voice_audition.cmd -All
```

To verify the checked-in RVC MP3-only review bundle without regenerating the full RVC WAV set:

```powershell
.\tools\verify_tracked_rvc_assets.cmd
```

Published prereleases also upload quick MP3 audition files as standalone GitHub release assets, so reviewers can play them without downloading the full ZIP. This includes the Stackchan Spark MP3s plus browser-friendly RVC review copies for the current lead, thinking, and safety lines. The same RVC review copies are also kept in `media/voice/rvc/` for local repository playback.

To audit the active production voice-source gate without generating package artifacts:

```powershell
.\tools\check_voice_source_readiness.cmd -Json
```

This should report `pending-production-voice-source` for prerelease work until a licensed or owned production voice source, consent/license evidence, completed provenance template, and target-speaker evidence are recorded. Use `-RequireProductionReady` only for consumer-promotion checks that must fail while the voice source is still pending.

To prepare the optional formant-source audition toolchain and rerender using eSpeak-NG when available:

```powershell
.\tools\setup_voice_tools.cmd -InstallEspeak -RenderEspeakSamples
```

If Windows Installer is busy or eSpeak-NG's MSI fails, rerun with `-ContinueOnInstallFailure` to capture a machine-readable setup status without changing the current review WAVs.

The package verifier rejects direct Git dependencies without refs and resolved Git dependencies without SHA evidence. Known upstream transitive declarations, such as the current `stackchan-arduino` `SCServo` Git dependency, must be recorded in `dependency_lock.json` instead of being hidden in console output.

Dry-run the release-binary flasher before connecting hardware:

```powershell
.\tools\flash_release_firmware.cmd -PackageZip output\release\stackchan_alive_<version>.zip -Firmware display_only -DryRun -Monitor -Port COM3
```

Create a hardware evidence packet when testing a physical device:

```powershell
.\tools\start_hardware_evidence.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

Packet creation copies the tested ZIP and records `logs/package_verify.log`. Promotion evidence must include that successful package-verification transcript unless the verifier is run with `-AllowMissingPackage` for a diagnostic-only packet.
The packet also includes generated `RUN_*.cmd` files for display flashing, servo calibration flashing, soak logging, package verification, final evidence verification, and the full consumer-promotion gate.

Verifier self-tests can generate an explicit diagnostic-only synthetic packet:

```powershell
.\tools\generate_synthetic_hardware_evidence.cmd -Version <version> -PackageZip output\release\stackchan_alive_<version>.zip -Verify
```

Synthetic packets are written under `output/hardware-evidence-diagnostic/`, include `BENCH_STATUS.md/json`, copied voice-gate reports, and a real `RUN_ROLLOUT_STATUS.cmd` to exercise the same handoff path as real packets. They are rejected by `tools\verify_hardware_evidence.cmd` unless `-AllowSyntheticEvidence` is passed. Do not use them as rollout evidence.

To prepare the release for arrival-day testing in one no-hardware-safe step:

```powershell
.\tools\prepare_device_arrival.cmd -ReleaseTag <version> -PackageZip output\release\stackchan_alive_<version>.zip -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

If you only have an extracted release ZIP, run the same helper from inside the extracted package folder:

```powershell
.\tools\prepare_device_arrival.cmd -Port COM3 -Operator "Your Name" -DeviceId STACKCHAN-001
```

Before promoting a prerelease, verify the completed hardware evidence packet:

```powershell
.\tools\verify_hardware_evidence.cmd -EvidenceRoot output\hardware-evidence\<packet-folder>
```

Then run the full consumer-promotion gate, which composes package verification, hardware evidence verification, GitHub Actions status, and production voice-source provenance:

```powershell
.\tools\verify_consumer_promotion.cmd -Version <version> -PackageZip output\release\stackchan_alive_<version>.zip -EvidenceRoot output\hardware-evidence\<packet-folder>
```

The promotion gate fails while the package voice source remains `pending-production-source` or while GitHub Actions status is not successful. The `-AllowExternalAccountCiBlock` switch exists only for an explicit account-billing or pre-runner allocation outage exception and must be paired with `-ExternalAccountCiExceptionPath docs/CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json` after that JSON is copied, completed, and approved for the exact release commit. The checked-in template is intentionally not approval-ready: its approval fields are `TBD` and every proof boolean is `false`. To start from the observed CI report, run `.\tools\new_ci_account_block_exception.cmd -ActionsStatusPath output\release\<version>\github_actions_status.json -OutPath output\ci-exceptions\<version>\CI_ACCOUNT_BLOCK_EXCEPTION_DRAFT.json`; the generated draft is also intentionally unapproved until the matching gate is genuinely satisfied.
The GitHub Actions status report records the required workflow set. For normal release promotion, both `Firmware` and `Release` must be present for the matching commit; a missing required workflow is a blocker even if another workflow succeeded.

## GitHub Release

For validated releases, push a tag:

```powershell
git tag <version>
git push origin <version>
```

The release workflow builds both firmware variants, runs native logic tests, compile-checks the embedded test firmware, renders preview media, creates and verifies an auditable package, and attaches the package, ZIP SHA256 sidecar, individual preview media, expression-sheet, and firmware files to a GitHub release.

If GitHub Actions cannot run, publish the already verified package with the manual release helper:

```powershell
.\tools\publish_release.cmd -Version <version> -CreateTag -PushCurrentBranch -PushTag
```

The manual helper verifies the local ZIP, uploads the same assets as the workflow, downloads the GitHub-hosted ZIP plus ZIP SHA256 sidecar, and verifies that remote copy against the tag commit.

Audit an existing GitHub release after publication:

```powershell
.\tools\verify_published_release.cmd -Version <version>
```

The published-release verifier checks the uploaded asset set, compares asset sizes and SHA256 digests against the local package, confirms the remote GitHub tag resolves to the expected package commit, downloads the GitHub ZIP plus ZIP SHA256 sidecar, validates the sidecar against the downloaded ZIP, and runs the package verifier on that downloaded copy.

For a single post-publish operator summary, run:

```powershell
.\tools\audit_published_release.cmd -Version <version>
```

The audit wraps the published-release verifier, refreshes GitHub Actions status, exports rollout status without requiring hardware evidence, and writes `RELEASE_AUDIT.md/json` under `output/release-audit/<version>/`. The publish helper runs the same audit with `-UploadToRelease` so the audit files are attached to the GitHub release after upload verification.

Stage a local handoff page with direct links to the ZIP, ZIP SHA256 sidecar, image, expression sheet, video, GIF, voice samples, voice-source provenance gate, release notes, readiness report, and checksums:

```powershell
.\tools\share_release.cmd -Version <version>
```

Add `-OpenLocal` to open the host-only local page automatically after the readiness probe passes.
For same-network phone/laptop review without Cloudflare, add `-Lan`. The helper binds to `0.0.0.0`, verifies the server through loopback, prints a host-only URL for this Windows machine, prints ranked LAN URL candidates for other devices, and records those candidates in `share_status.json` as `lanUrls`.
It also writes `OPEN_LOCAL_SHARE.cmd`, `LAN_TROUBLESHOOTING.md`, and `share_probe_report.json` with adapter metadata, virtual/VPN/no-gateway notes, and host-side reachability probes for the loopback and LAN candidate URLs. If a phone cannot open a LAN URL, first run `OPEN_LOCAL_SHARE.cmd` on the Windows host to prove the server is alive, then use the troubleshooting file and try a non-virtual candidate on the same Wi-Fi/LAN before falling back to Cloudflare.
If `cloudflared` is installed, add `-CloudflareTunnel` to start a tunnel for remote review. The script writes the static share folder under `output/share/<version>/`.
If `cloudflared` is not installed, add `-DownloadCloudflared` to place a local copy under `output/tools/` before starting the tunnel.
From an extracted release package, `tools/share_release.cmd` can infer the version from `release_manifest.json` and creates a temporary ZIP under `output/share/<version>/`.
When the quick tunnel URL is available, the script prints the public `trycloudflare.com` URL, writes it to `output/share/<version>/PUBLIC_URL.txt`, writes process and URL state to `share_status.json`, and keeps the local server plus tunnel running in hidden background processes. For `-Lan`, use the first printed same-network URL unless the machine is on a VPN-only or isolated network. A local-only share is acceptable for same-machine or LAN review after `verify_share_release.cmd` passes; the evidence packet writes the pinned URL to `share/VERIFIED_URL.txt`.
For a no-server static integrity check, run `tools/verify_share_release.cmd -Version <version> -Offline` after `tools/share_release.cmd -Version <version> -NoServe`. This writes `share_static_verification_report.json` with an `offline-static:` URL marker; it proves the share folder contents and hashes, but it is not hosted-media evidence because no URL was probed.
Run `tools/verify_share_release.cmd -Version <version> -RequirePublicUrl` before sending a public tunnel URL; omit `-RequirePublicUrl` for local or LAN review. It checks the handoff page plus the preview PNG, expression sheet, MP4, GIF, voice samples, voice-source provenance files, readiness report, readiness JSON, ZIP, ZIP SHA256 sidecar, and package checksums over HTTP.
Run `output/share/<version>/STOP_SHARING.cmd` or `tools/stop_share.cmd -Version <version>` to stop the local server and tunnel. If several old local shares are still running, `tools/stop_share.cmd -All` scans `output/share`, verifies each recorded PID still belongs to a share process, and stops the matching servers without trusting stale PID files blindly.

Use prerelease tags until the physical device has passed the rollout gates in `docs/PRODUCTION_READINESS.md`.

The hardware rollout checklist lives in `docs/ROLLOUT_CHECKLIST.md`.
