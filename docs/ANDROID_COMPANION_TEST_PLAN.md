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
- [ ] The foreground notification shows the same reachable manual fallback URL.

When using adb, install the APK and capture the install evidence before discovery checks:

Build the debug APK from the source checkout first unless a signed release APK is already
available:

```powershell
cd companion
.\gradlew.bat :app-android:assembleDebug
```

The default debug APK path is
`companion\app-android\build\outputs\apk\debug\app-android-debug.apk`.

```powershell
.\tools\install_android_companion_apk.cmd -ApkPath <path-to-apk>
# From a generated hardware evidence packet, prefer:
.\RUN_ANDROID_APK_INSTALL.cmd -ApkPath <path-to-apk>
```

The helper writes `output/android-apk-install/latest/ANDROID_APK_INSTALL.md`,
`android_apk_install.json`, `adb_install.log`, and `adb_dumpsys_package.txt`, or
`android/apk-install/` when run from an evidence packet. The report records the APK SHA256,
device model, package version, and install/update timestamps.

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

- [ ] Robot connects to the displayed Android URL or discovers it without manual entry.
- [ ] Android dashboard switches from waiting to connected and shows the robot identity, firmware/version signal, last bridge frame, active brain owner, and foreground service state.
- [ ] Android notification switches from waiting to session active.
- [ ] Robot receives `endpoint_hello`.
- [ ] Heartbeats continue for at least 10 minutes with the phone screen off.
- [ ] Android session wake lock is released after the robot disconnects.
- [ ] Reopening the app still shows the same endpoint identity.

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
- robot serial log covering connect, heartbeat, screen-off soak, and disconnect
- `android/logcat/ANDROID_COMPANION_LOGCAT.md`, `android_companion_logcat.json`, and `android_companion_logcat.txt` if the service stops, crashes, loses foreground status, or fails during screen-off soak
