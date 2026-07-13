# Stackchan: Alive Companion — Cross-Platform Build & Distribution Plan

Status: proposed implementation contract for building the `ANDROID_COMPANION_SPEC.md` app as
one codebase targeting Android + Windows + Linux (+ macOS), with a single release pipeline
that pushes updates to every platform from one git tag.

This document is a sibling to `ANDROID_COMPANION_SPEC.md`. That spec defines *what* the
companion is (protocol, owner semantics, settings surface, gates). This document defines
*how to build and ship it* on all platforms without forking it into per-OS products.

## Summary

- Build one Kotlin Multiplatform (KMP) + Compose Multiplatform project under `companion/`
  in this repo. Android and desktop (Windows/Linux/macOS) share ~90% of code: protocol data
  classes, endpoint WebSocket server, discovery, stores, owner state machine, and the UI
  screens themselves. Only mDNS bindings, the Android foreground service, and the desktop
  `lan_service.py` supervisor are platform-specific.
- The existing Python bridge stays canonical for PC Brain Mode. The desktop app does not
  reimplement STT/LLM/TTS; it supervises `bridge/lan_service.py` as a subprocess and
  additionally connects to the robot as its own observer endpoint for settings/diagnostics.
- One `v*` tag → one GitHub Actions run → all artifacts: signed APK to GitHub Releases,
  and self-updating Windows (MSIX), Linux (deb + apt repo), and macOS (Sparkle) packages
  built by Hydraulic Conveyor from a single Linux runner.
- Update distribution answer (the "or that might not be possible idk" question): **desktop
  updates are fully automatic** (MSIX background updates on Windows, apt on Linux, Sparkle
  prompt on macOS). **Android cannot silently self-update outside a store**; the honest
  ceiling is one-tap updates via an in-app updater or Obtainium, or full auto-update by
  publishing a Play closed track later. Details in "Update Distribution".
- The Kotlin protocol module is validated against the same JSON fixtures and the same
  Python virtual robot (`bridge/hardware_simulator.py`) that already gate the firmware and
  bridge, so the two implementations cannot silently drift.

## Framework Decision

Requirement set from the spec: Kotlin protocol data classes, an Android foreground service
holding a WebSocket bridge session, a LiteRT-LM adapter seam, desktop parity for settings/
diagnostics/handoff, local-first, and easy multi-OS update distribution.

| Option | Android fit | Desktop fit | Update story | Verdict |
| --- | --- | --- | --- | --- |
| **KMP + Compose Multiplatform** | Native. Foreground service, NSD, LiteRT-LM are first-class Kotlin. Spec's "Kotlin data classes" deliverable is literal shared code. | Compose Desktop is stable on Win/Linux/macOS; both targets are JVM-family so almost everything lives in `commonMain` (no Kotlin/Native needed). | Conveyor: self-updating native packages for all 3 desktop OSes, built from Linux CI, free for OSS. Android via APK/Play. | **Chosen.** |
| Flutter | Good, but LiteRT-LM/foreground-service/NSD all end up as Kotlin platform channels anyway; protocol classes become Dart, diverging from the spec deliverable. | Good. | Desktop auto-update is DIY (no built-in updater); Conveyor supports Flutter but the Kotlin duplication remains. | Viable fallback. |
| Tauri 2 | Mobile target works but is the youngest leg; services/LiteRT still require Kotlin plugin code. | Excellent, tiny binaries, built-in updater. | Good on desktop; Android same APK story. | Attractive if the UI were web-first; it is not. |
| Native Kotlin app + separate desktop app | Perfect | Perfect | Two codebases, two release trains — directly against the goal. | Rejected. |

Pre-registered falsifier for the choice (checked in Phase C0, before any real investment):
if the Compose Desktop spike cannot, on the Ubuntu workstation, (a) hold a Ktor WebSocket
server accepting a loopback client, (b) advertise/browse mDNS via jmDNS, and (c) minimize to
tray and survive 30 minutes idle without UI thread stalls, the KMP choice is falsified and
the fallback is Flutter with a thin Kotlin AAR for the Android service layer. Do not proceed
past C0 with an unfixed spike failure.

## What Already Exists and What This Plan Reuses

| Existing asset | Role in companion build |
| --- | --- |
| `ANDROID_COMPANION_SPEC.md` | The behavioral contract. Every message and gate there maps to a phase gate here. |
| `bridge/lan_service.py` (stdlib-only WebSocket server) | Canonical PC Brain runtime. Desktop app supervises it; desktop packages include the required bridge modules under packaged `brain/bridge/` resources. |
| `bridge/hardware_simulator.py` | Virtual robot / conformance counterparty for the Kotlin endpoint before hardware. |
| `bridge/reference_bridge.py` deterministic frames | Source of truth for golden JSON fixtures shared by Python, firmware bench, and Kotlin tests. |
| `docs/BRIDGE_PROTOCOL.md` | Wire format: WebSocket text = JSON control, binary = PCM16 up/downlink, lower_snake_case fields. |
| `tools/run_lan_smoke.cmd` flow | Template for the Kotlin-side LAN smoke gate (C5). |
| `.github/workflows/firmware.yml`, `release.yml` | Extended, not replaced: companion jobs are added with path filters and a shared tag trigger. |
| Character Lock harness + red-team suite | Unchanged final gate for any real Mobile Brain model (spec's last acceptance gate). |

Topology reminder (it shapes everything below): the robot is the WebSocket **client**. Every
endpoint — the Python PC bridge, the Android app, the desktop app — runs a WebSocket
**server** that the robot dials into, and the robot's trusted-endpoint registry decides who
it connects to and who owns the brain. Therefore the shared core's centerpiece is an
*endpoint server*, not a client, and it must run identically inside an Android foreground
service and a desktop tray process.

## Repository Layout

Keep the companion in this repo, not a sibling repo. Protocol changes, fixtures, firmware,
and both apps then move atomically in one PR, and the conformance tests can never test a
stale copy of the contract.

```
stackchan_alive/
  companion/
    settings.gradle.kts
    gradle/libs.versions.toml        # single version catalog, pinned
    conveyor.conf                    # desktop packaging + update site
    core/                            # KMP module: androidTarget + jvm
      src/commonMain/kotlin/
        protocol/                    # data classes for every spec message
        codec/                       # JSON <-> frame, binary PCM framing
        endpoint/                    # Ktor CIO WebSocket endpoint server
        discovery/                   # expect: MdnsAdvertiser, MdnsBrowser, UdpBeacon
        owner/                       # arbitration + heartbeat state machine
        store/                       # trusted robots/endpoints/settings (JSON files)
        engines/                     # SttEngine, LlmEngine, TtsEngine interfaces + fakes
      src/androidMain/kotlin/        # actual: NsdManager mDNS, multicast lock
      src/jvmMain/kotlin/            # actual: jmDNS, desktop paths
      src/commonTest/kotlin/         # fixture round-trip + state machine tests
    ui/                              # KMP module: shared Compose screens
      src/commonMain/kotlin/         # Devices, Pairing, Brain, Persona, Voice,
                                     # Settings, Diagnostics — all shared
    app-android/                     # Android entry: Activity, foreground service,
                                     # LiteRT-LM adapter, in-app updater
    app-desktop/                     # JVM entry: window+tray, lan_service.py
                                     # supervisor, Conveyor Control API updater
    mockrobot/                       # JVM CLI: Kotlin mock robot for tests/demos
  protocol-fixtures/                 # golden JSON, shared by Python + Kotlin + bench
    hello.json, endpoint_hello.json, claim_brain.json, ...
  bridge/                            # unchanged, plus test_protocol_fixtures.py
```

`protocol-fixtures/` sits at repo root, outside `companion/`, because three consumers read
it: Kotlin `commonTest`, Python `bridge/test_protocol_fixtures.py`, and (later) the firmware
bench replay. One file per message type, plus `invalid/` cases that every parser must reject
the same way.

## Shared Core Design

**Protocol module.** One `@Serializable` data class per message in the spec, using
kotlinx.serialization with `lower_snake_case` field names matching the Python style, unknown
keys ignored (forward compatibility), and a sealed `BridgeMessage` hierarchy keyed on
`type`. The codec module owns the rule from `BRIDGE_PROTOCOL.md`: text frames are JSON
control, binary frames are PCM16 payloads bracketed by `audio_stream_start` /
`audio_stream_end` (downlink) or `utterance_start` / `utterance_end` (uplink).

**Endpoint server.** Ktor `ktor-server-cio` in `commonMain` — CIO runs on both Android and
desktop JVM, so the entire accept/hello/heartbeat/turn loop is shared code. It exposes a
single `EndpointSession` state flow the UI observes. The server implements both roles from
the spec: observer (status, safe settings writes) and active brain owner (wake-gated audio
in, engine pipeline, TTS downlink out), with role switches driven only by `owner_status`
from the robot.

**Discovery.** `expect` interfaces in common, `actual` per platform: Android uses
`NsdManager` (plus `WifiManager.MulticastLock` held only while browsing/advertising),
desktop uses jmDNS. Both advertise `_stackchan-bridge._tcp.local` with TXT records
`endpoint_id`, `endpoint_kind`, `proto=stackchan.bridge.v1`, and the actual bound port —
never assume 8765 on the wire; the robot reads the port from the advert. UDP beacon
fallback and manual IP entry are pure common code.

**Owner state machine.** A small explicit FSM (`Idle → Observer → Claiming → Owner →
Releasing`) with heartbeat send/expiry timers, mirroring the spec's arbitration rules. It is
pure Kotlin with injected clock, so C4's handoff gates run as fast deterministic unit tests
before ever touching a socket.

**Engines.** `SttEngine` / `LlmEngine` / `TtsEngine` interfaces with deterministic fakes in
common code that byte-match the Python fakes' behavior (same canned transcript, same
Character-Lock-valid response, same WAV→PCM16 path). Real engines are platform `actual`s
added in C7 and are not accepted until they pass the same red-team and benchmark gates as
the PC path — restating the spec so it survives into the build plan.

**Stores.** Plain JSON files via kotlinx.serialization (app config dir per OS, `filesDir`
on Android). No database dependency in v1; the firmware side caps trusted endpoints at 8,
so the app-side registries stay trivially small.

## Desktop App Specifics

The desktop app has two jobs, cleanly separated:

1. **Observer endpoint** (shared code): its own `endpoint_id` (`endpoint_kind: "pc"`),
   paired like any endpoint, used for settings, diagnostics, persona/voice audition, forget,
   and handoff UI.
2. **PC Brain supervisor** (desktop-only): start/stop/health-check `python3
   bridge/lan_service.py ...` as a child process, stream its stdout into the Diagnostics
   screen, and surface its configured runner/STT/TTS commands. The Python service keeps its
   own endpoint identity as today; the GUI never proxies brain traffic. This costs one extra
   trust slot per PC (bridge + GUI) out of the 8 — acceptable, and it keeps the brain path
   byte-identical to what `run_lan_smoke` already certifies.

Python dependency policy for v1: require `python3` ≥ 3.10 on PATH (the bridge is
stdlib-only, so there is no pip step). Packaging a frozen bridge binary inside the app is a
later optimization, not a blocker — track it as C8 optional work.

Tray behavior: close-to-tray with the endpoint server still listening, matching the
Android foreground-service semantics so "the robot can always reach a trusted endpoint"
means the same thing on both platforms.

## Android App Specifics

- Foreground service (`foregroundServiceType="connectedDevice|dataSync"`) owns the Ktor
  endpoint server, NSD registration, heartbeats, and — when brain owner — the engine
  pipeline. Partial wake lock held only while a session is active; multicast lock only
  while discovery runs. Battery-optimization exemption is requested with an explanation
  screen, not silently.
- Permissions: `INTERNET`, `ACCESS_NETWORK_STATE`, `CHANGE_WIFI_MULTICAST_STATE`,
  `FOREGROUND_SERVICE` (+ type), `POST_NOTIFICATIONS`, `CAMERA` only when the QR pairing
  screen is open, `RECORD_AUDIO` only for the explicit phone-mic test harness (spec: off by
  default, wake-gated audio comes from the robot, not the phone), and
  `REQUEST_INSTALL_PACKAGES` only if the in-app updater ships (see distribution).
- LiteRT-LM seam: an `actual LlmEngine` wrapping the same contract as
  `bridge/litert_lm_stackchan_wrapper.py`, loading nothing until a model profile is
  explicitly installed; until then the deterministic fake is the runner and the UI labels
  Mobile Brain as "fake engine" so no one mistakes a demo for a brain candidate.
- Min SDK 26, target latest stable; keep the app pure-Kotlin/JVM so `core` needs no NDK.

## Toolchain Pins

Pin everything in `gradle/libs.versions.toml` and record the resolved set in release
evidence. Suggested opening set (verify latest stable at C0 and freeze):

| Component | Pin policy |
| --- | --- |
| JDK | 21 (Temurin), same in CI and Conveyor's bundled JVM |
| Kotlin / KMP | latest stable 2.x at C0, then frozen per release branch |
| Compose Multiplatform | latest stable at C0 |
| Ktor (client+server CIO) | latest stable 3.x |
| kotlinx.serialization / coroutines | matching Kotlin pin |
| jmDNS (desktop) | 3.5.x |
| Android Gradle Plugin / SDK | AGP stable, compileSdk latest, minSdk 26 |
| Conveyor | pinned major (18+), invoked via its GitHub Action |
| Python (PC brain) | ≥ 3.10 system interpreter, stdlib only |

## Build & CI

Extend the existing workflows; do not create a second release universe.

Current PR gate in `.github/workflows/firmware.yml`: companion changes run the shared
`companion-tests` job plus `companion-platform-builds`, a four-leg matrix that builds
Android debug/release APKs on Ubuntu, a Linux `.deb` on Ubuntu, a macOS `.dmg` on macOS,
and a Windows `.msi` on Windows. Every leg provisions JDK 21 and Android SDK Platform 36 so
the shared KMP Android targets are configured consistently even during desktop packaging,
and every leg uploads its produced platform artifact with `if-no-files-found: error`.
A follow-on `companion-release-evidence` job downloads those four platform artifacts,
runs `tools/export_companion_release_evidence.ps1 -RequireArtifacts`, verifies the Android
release APK with `apksigner`, and uploads `COMPANION_RELEASE_EVIDENCE.json/md` with
artifact paths, byte counts, SHA256 hashes, the producing commit, Gradle toolchain pins,
and Android signing status. That evidence job fails if the manifest does not include both
Android debug/release APKs, a verified signed release APK, plus Linux `.deb`, macOS `.dmg`,
and Windows `.msi` desktop packages.

Evidence snapshot: PR #194 run `28711092216` on 2026-07-04 passed `bridge-tests`,
`native-tests`, firmware `build`, `companion-tests`, all four platform artifact legs, and
`companion-release-evidence`. Uploaded companion artifacts included `companion-android-apks`,
`companion-desktop-linux`, `companion-desktop-macos`, `companion-desktop-windows`, and a
complete `COMPANION_RELEASE_EVIDENCE.json/md` manifest. The release APK entry is
`app-android-release.apk`; the signing evidence records APK Signature Scheme v2 with the
Android debug certificate for lab/arrival-day testing.

**PR / push (`firmware.yml` additions, path-filtered to `companion/**` and
`protocol-fixtures/**`):**

```yaml
  companion-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-java@v5
        with: { distribution: temurin, java-version: "21" }
      - uses: gradle/actions/setup-gradle@v4
      - run: cd companion && ./gradlew check koverXmlReport
      - name: Cross-implementation conformance
        run: |
          python -m unittest bridge.test_protocol_fixtures
          cd companion && ./gradlew :core:jvmTest --tests "*FixtureConformance*"
      - name: Kotlin endpoint vs Python virtual robot smoke
        run: cd companion && ./gradlew :mockrobot:lanSmoke   # drives hardware_simulator.py
```

**Tag `v*` (`release.yml` additions):**

```yaml
  companion-android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-java@v5
        with: { distribution: temurin, java-version: "21" }
      - name: Decode keystore
        run: echo "$ANDROID_KEYSTORE_B64" | base64 -d > companion/release.keystore
        env: { ANDROID_KEYSTORE_B64: ${{ secrets.ANDROID_KEYSTORE_B64 }} }
      - run: cd companion && ./gradlew :app-android:assembleRelease
        env:
          KEYSTORE_PASSWORD: ${{ secrets.KEYSTORE_PASSWORD }}
          KEY_ALIAS: companion
      - run: sha256sum companion/app-android/build/outputs/apk/release/*.apk > APK_SHA256.txt
      - uses: softprops/action-gh-release@v2
        with: { files: "companion/app-android/build/outputs/apk/release/*.apk,APK_SHA256.txt" }

  companion-desktop:
    runs-on: ubuntu-latest        # Conveyor cross-builds Win/mac/Linux from Linux
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-java@v5
        with: { distribution: temurin, java-version: "21" }
      - run: cd companion && ./gradlew :app-desktop:jvmJar
      - uses: hydraulic-software/conveyor/actions/build@master
        with:
          command: make copied-site
          signing_key: ${{ secrets.CONVEYOR_SIGNING_KEY }}
          agree_to_license: 1
      - uses: softprops/action-gh-release@v2
        with: { files: "output/*" }   # packages + update metadata to the release
```

Secrets to provision once: `ANDROID_KEYSTORE_B64` + passwords (generate the keystore
locally, back it up — losing it breaks Android update continuity permanently),
`CONVEYOR_SIGNING_KEY` (self-signed root generated by `conveyor keys generate`). Optional
later: a real Windows code-signing cert and an Apple Developer ID for notarization.

Every release job also emits `RELEASE_EVIDENCE.json` — artifact paths, sha256 sums, git
commit, toolchain pins — matching the provenance pattern the repo already uses.

## Update Distribution

The direct answer to "distribute updates to all — or is that not possible":

| Platform | Mechanism | User experience after v1 install | Automatic? |
| --- | --- | --- | --- |
| Windows | Conveyor MSIX + `.appinstaller` on GitHub Releases | Windows updates it in the background, even when not running | Yes, silent |
| Linux (Debian/Ubuntu) | Conveyor-generated deb + apt repo (flat files on the release/Pages) | Updates arrive with normal `apt upgrade` / Software Updater | Yes, with system updates |
| Linux (other) | Tarball | Manual download | No |
| macOS | Conveyor app bundle with Sparkle 2 | Sparkle prompts "update available", one click | Yes, prompted |
| Android (chosen path) | APK on GitHub Releases + in-app updater: check releases API → download → PackageInstaller session | App shows "update available", user taps once, system install dialog confirms | Semi — one tap per update, OS-enforced |
| Android (zero-code alt) | Obtainium pointed at the repo | Obtainium notifies and installs on tap | Semi |
| Android (full auto) | Play Store closed track | Silent background updates | Yes, but Play account, review, and data-safety forms |

So: one tag updates everything, with exactly one caveat — Android's sandbox forbids silent
self-updates for sideloaded apps by design. One-tap is the honest ceiling until/unless a
Play track is worth the overhead. Recommendation: ship the in-app updater (it also verifies
the APK sha256 from `RELEASE_EVIDENCE.json` before invoking the installer) and document
Obtainium as the alternative.

`conveyor.conf` starting point:

```hocon
include required("/stdlib/jdk/21/openjdk.conf")
include required("#!./gradlew -q printConveyorConfig")

app {
  display-name = "Stackchan Companion"
  rdns-name = dev.aeternum.stackchan.companion
  vcs-url = "https://github.com/RobVanProd/stackchan_alive"   # OSS => Conveyor free
  site.base-url = "github.com/RobVanProd/stackchan_alive/releases/latest/download"
  updates = aggressive        # check on every launch; endpoint apps should be current
  machines = [ windows.amd64, linux.amd64, mac.amd64, mac.aarch64 ]
}
```

Known rough edges, stated up front rather than discovered later: self-signed Windows
packages trip SmartScreen on first install (users click through once; a paid cert removes
it); un-notarized macOS builds need right-click → Open (an Apple Developer ID, $99/yr,
removes it); the apt path covers Debian-family only. None of these block the lab/streaming
use case.

**Out of scope, explicitly:** robot firmware updates. Those remain the PlatformIO/USB flow
in `docs/RELEASE_PROCESS.md`. The companion spec grants the app no firmware-flash
capability, and this plan does not invent one.

## Versioning & Compatibility

- App semver `MAJOR.MINOR.PATCH`, one version string shared by all platforms per tag, sent
  in `endpoint_hello.app_version`.
- `stackchan.bridge.v1` stays additive: new message types and new optional fields only;
  unknown types are ignored and logged by every parser (fixtures include this case). A
  breaking change requires `v2` plus dual-stack support in the app for one release cycle.
- Capability negotiation, not version sniffing: features gate on the `capabilities` arrays
  from `hello`/`endpoint_hello`, exactly as the spec models them.
- The fixtures directory is the compatibility contract. A release is blocked if Python and
  Kotlin disagree on any fixture (semantic JSON equality, not byte equality — key order is
  not part of the contract).

## Phased Build Plan

Phases are prefixed C (companion) to avoid colliding with the face animation Phases A–E.
Each gate names its evidence artifact; evidence means committed files with sha256 sums and
the producing commit hash, per house rules. No phase starts before the prior gate's
evidence exists.

**C0 — Scaffold & falsification spike.**
Gradle project, version catalog, empty-but-launching Android app and desktop app, CI
`companion-tests` job green, plus the desktop spike from "Framework Decision" (WS server +
jmDNS + tray, 30-min idle).
*Gate C0:* both apps launch and display app version + protocol constant; spike log
committed as `output/companion/c0-spike/SPIKE.md` with pass/fail per criterion. A spike
failure here triggers the pre-registered Flutter fallback, not a workaround.

**C1 — Protocol module & conformance.**
Every message in `ANDROID_COMPANION_SPEC.md` and `docs/BRIDGE_PROTOCOL.md` as a data class;
`protocol-fixtures/` populated from `reference_bridge.py` output; Python + Kotlin fixture
tests; invalid-input cases rejected identically.
*Gate C1:* fixture matrix report (`c1-conformance/CONFORMANCE.json`) shows every message ×
{kotlin-encode, kotlin-decode, python-decode} green, including unknown-type tolerance.

**C2 — Endpoint server, discovery, pairing.**
Ktor endpoint server in the shared core; mDNS advertise/browse actuals on both platforms;
UDP beacon + manual IP; pairing flow (short code + QR + fingerprint confirm) against the
Kotlin `mockrobot` and against `hardware_simulator.py`.
*Gate C2:* the Python virtual robot discovers, pairs with, and completes `hello`/
`endpoint_hello` + heartbeats against the Kotlin endpoint on Android *and* desktop over a
real LAN segment; transcript committed.

**C3 — Settings surface & endpoint registry.**
`settings_get`/`settings_set` with version-conflict handling, all domains from the spec;
`trusted_endpoints` + `forget_endpoint`; foundation-locked settings hard-rejected in the
shared core (not just hidden in UI).
*Gate C3:* spec gates "settings round trip incl. version conflict", "forget prevents
auto-reconnect until re-paired", and "safety-locked settings cannot be changed from the
app" each pass against the simulator, with a negative test proving the lock.

**C4 — Owner semantics & handoff.**
Arbitration FSM + heartbeat expiry; claim/release/owner_status; observer restrictions
enforced (an observer socket receiving audio is a test failure, not a warning).
Post-release source status: the Python bridge and shared Kotlin core now use the same 15-second
owner lease, capability-filtered promotion, explicit-claim precedence, priority/recency automatic
selection, and offline fallback. Protocol conformance includes the Conversation v2 reply-window
and playback-complete messages. `bridge/lan_smoke.py --scenario owner-failover` exercises PC claim,
observer-audio rejection, timeout promotion to phone, and explicit handback to PC through the real
local WebSocket path, followed by offline fallback when both endpoint leases expire. Target-device
two-endpoint evidence is still pending.
*Gate C4:* PC → mobile → PC handoff on the simulator with zero firmware-settings writes;
owner-timeout promotion; offline fallback when no endpoint is healthy. Deterministic FSM
unit tests plus one live two-endpoint LAN run, both in evidence.

**C5 — Audio path with fake engines.**
Binary PCM16 uplink after `utterance_start`; fake STT/LLM/TTS chain; `audio_stream_start`
→ chunks → `audio_stream_end` downlink; cancel/barge-in and mid-stream owner-loss abort.
*Gate C5:* a Kotlin-side LAN smoke equivalent of `tools/run_lan_smoke.cmd` writes
`c5-lan-smoke/LAN_SMOKE.json` with the same checks (frame order, chunk accounting,
thinking-latency) passing for the Kotlin endpoint as brain owner.

**C6 — Desktop brain supervision & diagnostics.**
`lan_service.py` subprocess lifecycle in the desktop app; log streaming; diagnostics
screens on both platforms; exportable diagnostics JSON suitable for release evidence.
*Gate C6:* start → robot(sim) turn through the Python brain → stop → restart, driven
entirely from the GUI; exported diagnostics attached as evidence.

**C7 — Real Mobile Brain candidate.**
LiteRT-LM `actual` engine behind the C1 contract; model profile install flow;
benchmark + Character Lock red-team runs on-device.
*Gate C7:* identical to the spec's final gate — the mobile model passes the same red-team
and benchmark gates as the PC path before the UI may label it a real brain candidate.
Until then the label stays "fake engine".

**C8 — Distribution hardening.**
Keystore + Conveyor keys provisioned; release workflow additions live; in-app Android
updater with sha256 verification; first end-to-end tagged release.
*Gate C8:* from tag push with no manual steps: APK installs and later self-update-prompts
on a phone; Windows package background-updates across two consecutive test tags; Linux apt
upgrade works on the workstation; `RELEASE_EVIDENCE.json` complete.

Sequencing note: C1–C5 run entirely against simulators and need no hardware; C2's LAN leg
and everything in C7–C8 want the real phone and workstation. Firmware-side work the spec
assumes (multi-endpoint registry, concurrent trusted connections, owner arbitration on
device) is tracked as separate firmware PRs and is *not* a dependency for C0–C6 thanks to
the simulator.

## Risks & Pre-Registered Falsifiers

- **Compose Desktop stability on Linux** — falsifier and fallback defined in C0; do not
  rationalize a flaky spike.
- **Android background killing** breaks the "robot can always reach the phone" promise on
  aggressive OEMs. Mitigation: foreground service + exemption flow; falsifier: if the C4
  live run shows heartbeat loss during a 2-hour screen-off soak on the target phone,
  Mobile Brain gets a "screen-on / charging recommended" constraint in-product rather than
  a silent reliability lie.
- **mDNS on real home networks** is famously unreliable; that is why the spec's UDP beacon
  and manual IP are mandatory C2 deliverables, not stretch goals.
- **Ktor CIO server on Android** is the one moderately unusual dependency use. If C2
  exposes blocking issues, the contained fallback is a raw `ServerSocket` + the same
  hand-rolled WebSocket framing `lan_service.py` already proves is small (one file,
  stdlib) — the protocol layer above it does not change.
- **Trust/session security** (TLS vs Noise-style keys) is deliberately deferred by the
  spec until firmware budget is known; the pairing fingerprint field is carried through
  from C2 so retrofitting authenticated sessions does not change the message shapes.
- **Keystore loss** permanently severs Android update continuity — back it up offline the
  day it is generated.

## First Three PRs

1. `companion: C0 scaffold` — Gradle project, catalogs, empty apps, CI job, spike report.
2. `protocol-fixtures + bridge: fixture export & Python conformance test` — generate
   goldens from `reference_bridge.py`, add `bridge/test_protocol_fixtures.py` (pure
   addition, no behavior change to the bridge).
3. `companion: C1 protocol module` — data classes + codec + conformance green on CI.

Everything after that follows the phase table, one gate per PR chain, evidence attached.
