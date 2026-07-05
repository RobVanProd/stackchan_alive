# Android Play Policy Declarations

This document is the source-side answer sheet for the first Stackchan Companion
Google Play internal-testing submission. It must be re-reviewed against the exact
uploaded build before anything leaves internal testing.

Authoritative policy references checked for this source review:

- Google Play Data safety form:
  https://support.google.com/googleplay/android-developer/answer/10787469
- Android foreground service type declaration:
  https://developer.android.com/develop/background-work/services/fgs/declare
- Android 14+ foreground service type / Play Console declaration:
  https://developer.android.com/about/versions/14/changes/fgs-types-required
- Play app-content review page:
  https://support.google.com/googleplay/android-developer/answer/9859455

## Play Console App Content

- Privacy policy URL: required before closed/open/production testing. The hosted
  page must be derived from `docs/PRIVACY.md` plus this declaration and must name
  the Android package `dev.stackchan.companion`.
- Ads: no ads.
- App access: no login account. Access requires a Stack-chan robot on the same
  LAN for the meaningful connected flows. Review notes must explain that the app
  can still open without hardware, but connected screenshots and evidence come
  from the internal test packet.
- Target audience: not directed to children.
- News, health, financial, government, and location-sensitive use: not applicable.

## Data Safety Draft

Current source behavior for `dev.stackchan.companion`:

| Play data category | Declaration | Evidence and boundary |
| --- | --- | --- |
| Personal info | Not collected | No account, name, email, phone number, or address fields exist. |
| Financial info | Not collected | No payments or purchases. |
| Location | Not collected | The app uses local-network state and LAN IPs, not Android location permissions. |
| Photos/videos | Not collected | No camera/gallery permissions or upload path. Store screenshots are operator-created evidence outside app runtime. |
| Audio files | Not collected | `RECORD_AUDIO` is used only after tapping Push-to-talk. Android SpeechRecognizer returns a transcript; raw microphone audio is not stored or exported by the app. |
| Voice or sound recordings | Not collected | The app does not persist raw microphone audio. Diagnostics redact the last text turn to a presence-only flag. |
| App activity | Not collected by developer | Local settings, saved robots, trusted endpoints, model asset state, and diagnostics remain on-device unless the user explicitly shares an export. |
| App info and performance | Not collected by developer | Crash/log exports are not automatic. Logcat capture is an external arrival-day evidence tool, not app telemetry upload. |
| Device or other IDs | Not collected by developer | The app stores local endpoint IDs, robot IDs, fingerprints, and bridge URLs on-device for pairing. They are not uploaded by the app. |

Data sharing: none by the app. The only external transfer is user-initiated sharing
from Android's share sheet when exporting diagnostics. That export is local JSON,
redacts transcript text, records model/provisioning state, and uses password
placeholders for Wi-Fi provisioning with `password_redacted=true`.

Data deletion: users can remove saved robot rows and trusted companion rows from
the app UI. Android app uninstall removes app-private local stores. Robot-side
unpairing still requires firmware support and must not be implied in Play copy.

Security practices:

- Data is transmitted only over the user's local network bridge, not to a cloud
  endpoint controlled by this app.
- No Play release may claim consumer-ready status until real hardware evidence,
  production voice-source provenance, and final policy review are complete.

## Permission And Policy Declaration Draft

| Permission or capability | Play-facing justification |
| --- | --- |
| `INTERNET` | Hosts and connects to the local WebSocket bridge used by Stack-chan on the user's LAN. |
| `ACCESS_NETWORK_STATE` | Shows whether the phone is ready for local robot pairing and bridge hosting. |
| `CHANGE_WIFI_MULTICAST_STATE` | Allows mDNS/UDP local discovery for Stack-chan pairing. |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_CONNECTED_DEVICE` | Keeps the user-visible robot bridge alive while the phone is the active companion. The foreground notification shows bridge status. |
| `POST_NOTIFICATIONS` | Shows the foreground bridge-service notification on Android 13+. |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Optional arrival-day reliability prompt for screen-off bridge soak testing. Do not present this as mandatory for ordinary app browsing. |
| `WAKE_LOCK` | Keeps the active robot bridge session from sleeping during connected testing. |
| `RECORD_AUDIO` | Enables explicit Push-to-talk. Denial leaves the turn unsent; raw audio is not exported in diagnostics. |

Foreground service Play Console draft:

- Type: `connectedDevice`
- User-visible task: hosting the local Stack-chan bridge while the robot is
  connected to this phone.
- User benefit: the robot can keep receiving local companion control, text turns,
  brain ownership, settings writes, and diagnostics while the app remains the
  active bridge.
- Why not a short background task: the robot bridge is an active device session
  that must remain reachable while the user tests or operates the physical robot.
- Evidence required before submission: connected Android dashboard screenshot,
  foreground notification state, screen-off bridge soak, and logcat capture if
  the service stops or crashes.

## Play Store Evidence Packet Requirements

Before upload beyond source readiness, `output/android-play-store/latest` must
contain:

- `PLAY_STORE_EVIDENCE.json` with full source commit, AAB SHA-256, Play App
  Signing enabled, internal test status, and at least two final-build screenshots.
- `DATA_SAFETY_REVIEW.md` reviewed against this document and the uploaded build.
- `POLICY_REVIEW.md` reviewed against manifest permissions, foreground service
  behavior, and battery optimization copy.
- Screenshots from the final Android build, not simulator mockups.

The source tree can be ready while this packet remains pending; public rollout
cannot.
