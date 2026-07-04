# Android Companion Physical Test Plan

Use this checklist when validating the Android companion on the target phone and the same
LAN as the physical Stackchan. Keep the app as a prerelease until every required item has
captured evidence.

## Scope

This plan covers the Android companion bridge only:

- foreground bridge service on `ws://<phone-lan-ip>:8765/bridge`
- Android NSD advertisement for `_stackchan-bridge._tcp.local`
- UDP beacon fallback on port `8766`
- manual URL fallback shown in the Android dashboard and foreground notification
- notification permission, battery-optimization exemption, multicast lock, and session wake lock behavior

The app intentionally declares the bridge service as `connectedDevice` only. Do not add
`dataSync` for the long-running bridge service unless the service is redesigned to stop
within Android's time-limited data-sync window. The bridge needs to stay reachable during
screen-off robot sessions, which matches the connected-device foreground-service role.

## Preflight

- [ ] Phone and robot are on the same Wi-Fi/LAN segment.
- [ ] VPN, private DNS filtering, guest Wi-Fi isolation, and mobile hotspot client isolation are off unless intentionally being tested.
- [ ] The installed APK version and git commit are recorded.
- [ ] Android notifications are allowed for Stackchan Companion.
- [ ] Battery optimization exemption is allowed or the denial is recorded as a test constraint.
- [ ] The dashboard shows at least one `ws://<phone-lan-ip>:8765/bridge` manual fallback URL.
- [ ] The dashboard endpoint registry shows this phone's persisted Android endpoint ID, not sample placeholder endpoints.
- [ ] The Nodes screen shows the guided `Add your Stack-chan` setup flow with the same manual URL.
- [ ] Removing a stored trusted companion endpoint updates the registry without restarting the app.
- [ ] The foreground notification shows the same reachable manual fallback URL.

When using adb, install the APK and capture the install evidence before discovery checks:

Build the lab-signed release APK from the source checkout first. The v1 PR/CI release APK
is signed with the Android debug key for physical testing, not for public distribution:

```powershell
.\tools\check_companion_v1_readiness.cmd
.\tools\check_android_toolchain.cmd
cd companion
.\gradlew.bat :app-android:assembleRelease
```

The companion readiness check verifies the v1 companion plan, protocol fixtures, KMP
source tree, CI hooks, Android foreground service, and pending hardware gates before
phone-specific APK evidence starts.

The toolchain check verifies `JAVA_HOME`/`java.exe`, Android SDK root, `platform-tools`/`adb.exe`,
and SDK Platform 36 before Gradle starts.

The default lab release APK path is
`companion\app-android\build\outputs\apk\release\app-android-release.apk`.

```powershell
.\tools\install_android_companion_apk.cmd -ApkPath <path-to-apk>
# From a generated hardware evidence packet, prefer:
.\RUN_ANDROID_APK_INSTALL.cmd -ApkPath <path-to-apk> -SourceCommit <git-commit>
```

The helper writes `output/android-apk-install/latest/ANDROID_APK_INSTALL.md`,
`android_apk_install.json`, `adb_install.log`, and `adb_dumpsys_package.txt`, or
`android/apk-install/` when run from an evidence packet. The report records the APK SHA256,
source commit, device model, package version, and install/update timestamps. If
`-SourceCommit` is omitted, the helper records the current `git rev-parse HEAD` value when
run from a source checkout.

## Discovery Checks

Run these from another machine on the same LAN when available.

```powershell
Resolve-DnsName _stackchan-bridge._tcp.local -Type PTR
```

Expected:

- [ ] The Android bridge appears as `_stackchan-bridge._tcp.local`, or mDNS failure is recorded with router/client-isolation notes.
- [ ] TXT metadata includes `endpoint_id`, `endpoint_kind=android`, `proto=stackchan.bridge.v1`, and `capabilities`.

If mDNS does not resolve, test the UDP fallback:

```powershell
.\tools\run_android_udp_beacon_probe.cmd
# From a generated hardware evidence packet, prefer:
.\RUN_ANDROID_UDP_BEACON_PROBE.cmd
```

The helper listens on UDP port `8766` and writes
`output/android-udp-beacon/latest/ANDROID_UDP_BEACON_PROBE.md` plus
`android_udp_beacon_probe.json`, or `android/udp-beacon-probe/` when run from an
evidence packet. Expected:

- [ ] `tools/run_android_udp_beacon_probe.cmd` captures a `stackchan_bridge_beacon` JSON payload.
- [ ] The payload endpoint ID matches the Android dashboard identity.
- [ ] The payload port is `8765`.

If both discovery paths fail, use the dashboard or notification URL directly.

## Manual Bridge Probe

Probe the displayed URL before asking the robot to connect:

```powershell
.\tools\run_android_companion_probe.cmd -Url ws://<phone-lan-ip>:8765/bridge
# From a generated hardware evidence packet, prefer:
.\RUN_ANDROID_COMPANION_PROBE.cmd -Url ws://<phone-lan-ip>:8765/bridge
```

The helper writes `output/android-companion-probe/latest/ANDROID_COMPANION_PROBE.md` and
`android_companion_probe.json`, or `android/companion-probe/` when run from an evidence
packet. The expected first server text frame is `endpoint_hello` with Android endpoint
metadata.

Evidence to capture:

- [ ] displayed manual URL
- [ ] `tools/run_android_companion_probe.cmd` passes against `/bridge`
- [ ] `endpoint_hello.endpoint_kind` is `android`
- [ ] `endpoint_hello.protocol` is `stackchan.bridge.v1`
- [ ] advertised capabilities include settings/diagnostics and brain ownership capability if enabled for the test build

## Robot Session

- [ ] The **Add your Stack-chan** setup card shows the live phone bridge URL and the three setup states: Start phone bridge, Connect Stack-chan, and Confirm robot ready.
- [ ] The disconnected robot row shows a waiting/setup action rather than an unavailable handoff action.
- [ ] The setup card shows how many trusted companion nodes are stored before the operator removes or keeps old devices.
- [ ] Robot connects to the displayed Android URL or discovers it without manual entry.
- [ ] Android dashboard switches from waiting to connected and shows the robot identity, firmware/version signal, last bridge frame, active brain owner, and foreground service state.
- [ ] Android notification switches from waiting to session active.
- [ ] Robot receives `endpoint_hello`.
- [ ] Heartbeats continue for at least 10 minutes with the phone screen off.
- [ ] Android session wake lock is released after the robot disconnects.
- [ ] Reopening the app still shows the same endpoint identity.

Run the screen-off soak helper while the phone is the active bridge host and the robot is
connected:

```powershell
.\tools\run_android_companion_soak.cmd -Url ws://<phone-lan-ip>:8765/bridge
# From a generated hardware evidence packet, prefer:
.\RUN_ANDROID_SCREEN_OFF_SOAK.cmd -Url ws://<phone-lan-ip>:8765/bridge
```

The helper samples the Android bridge for 10 minutes by default and writes
`output/android-companion-soak/latest/ANDROID_COMPANION_SOAK.md` and
`android_companion_soak.json`, or `android/screen-off-soak/` when run from an evidence
packet. Leave `-DurationSeconds 600 -IntervalSeconds 30 -MaxFailures 0` at the strict
defaults for v1 release evidence unless the test owner explicitly approves a diagnostic
rerun.

## Handoff And Failure Cases

- [ ] If desktop and Android endpoints are both trusted, only one endpoint is active brain owner.
- [ ] Disconnecting the active owner releases or promotes ownership according to priority.
- [ ] Turning Wi-Fi off causes a clean robot disconnect or heartbeat expiry.
- [ ] Turning Wi-Fi back on lets the robot reconnect or rediscover the Android endpoint.
- [ ] Stopping the foreground service makes the robot fall back to another healthy endpoint or offline behavior.

If the Android service stops, crashes, loses foreground status, or fails during screen-off
soak, capture adb evidence immediately:

```powershell
.\tools\capture_android_companion_logcat.cmd
# From a generated hardware evidence packet, prefer:
.\RUN_ANDROID_LOGCAT_CAPTURE.cmd
```

The helper writes `output/android-logcat/latest/ANDROID_COMPANION_LOGCAT.md`,
`android_companion_logcat.json`, and `android_companion_logcat.txt`, or
`android/logcat/` when run from an evidence packet. Use `-Serial <device-serial>` when
multiple adb devices are connected and `-Lines <count>` when the failure has scrolled
farther back in the device buffer.

## Evidence

Attach these to the arrival-day packet:

- screenshot of the Android dashboard manual URL
- screenshot of the Android dashboard connected robot state, including robot identity, firmware/version signal, last bridge frame, active brain owner, and service state
- screenshot of the foreground notification
- `android/apk-install/ANDROID_APK_INSTALL.md`, `android_apk_install.json`, and `adb_install.log`, or the repo `output/android-apk-install/latest/` equivalents
- mDNS result or failure note
- `android/udp-beacon-probe/ANDROID_UDP_BEACON_PROBE.md` and `android_udp_beacon_probe.json`, or the repo `output/android-udp-beacon/latest/` equivalents
- `android/companion-probe/ANDROID_COMPANION_PROBE.md` and `android_companion_probe.json`, or the repo `output/android-companion-probe/latest/` equivalents
- `android/screen-off-soak/ANDROID_COMPANION_SOAK.md` and `android_companion_soak.json`, or the repo `output/android-companion-soak/latest/` equivalents
- robot serial log covering connect, heartbeat, screen-off soak, and disconnect
- `android/logcat/ANDROID_COMPANION_LOGCAT.md`, `android_companion_logcat.json`, and `android_companion_logcat.txt` if the service stops, crashes, loses foreground status, or fails during screen-off soak
