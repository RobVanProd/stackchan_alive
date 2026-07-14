# Android Play Policy Declarations

This document is the source-side answer sheet for the first Stackchan Companion
Google Play internal-testing submission. It must be re-reviewed against the exact
uploaded build before anything leaves internal testing.

Authoritative policy references checked for this source review:

- Google Play Data safety form:
  https://support.google.com/googleplay/android-developer/answer/10787469
- Google Play User Data policy:
  https://support.google.com/googleplay/android-developer/answer/10144311
- Android foreground service type declaration:
  https://developer.android.com/develop/background-work/services/fgs/declare
- Android 14+ foreground service type / Play Console declaration:
  https://developer.android.com/about/versions/14/changes/fgs-types-required
- Play app-content review page:
  https://support.google.com/googleplay/android-developer/answer/9859455

## Play Console App Content

- Privacy policy URL:
  https://robvanprod.github.io/stackchan_alive/privacy/. The hosted page source
  is `site/privacy/index.html`; it is reviewed with
  `docs/ANDROID_PLAY_PRIVACY_POLICY.md` and names the Android package
  `dev.stackchan.companion`. GitHub Pages build `1094346889` published the exact
  source bytes from commit `afbebbd3429e00a6f76cb238788ce7664f1b6fda` on
  July 14, 2026. The HTTPS response returned `200` and matched source SHA-256
  `28d1cca7889f8d95c0587025ee5d46c213a85ac814c538e3c36090b377fd1f47`.
  `docs/store-assets/play/PRIVACY_POLICY_DEPLOYMENT.json` preserves the public
  deployment identity; `tools/check_privacy_policy_deployment.ps1 -Json`
  revalidates the current URL and exact bytes before a Play upload.
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
| Audio files | Not collected | The app does not import, persist, or upload audio files. |
| Voice or sound recordings | Collected only for optional, ephemeral app functionality | `RECORD_AUDIO` is used only after tapping Push-to-talk. The configured Android SpeechRecognizer may transmit microphone audio to its provider even though the app requests offline recognition. The app does not retain raw audio or export it in diagnostics. Confirm the exact Play form selections against the final test device and recognizer provider. |
| App activity | Not collected by developer | Local settings, saved robots, trusted endpoints, model asset state, and diagnostics remain on-device unless the user explicitly shares an export. |
| App info and performance | Not collected by developer | Crash/log exports are not automatic. Logcat capture is an external arrival-day evidence tool, not app telemetry upload. |
| Device or other IDs | Not collected by developer | The app stores local endpoint IDs, robot IDs, fingerprints, and bridge URLs on-device for pairing. They are not uploaded by the app. |

The app does not automatically send data to the developer or an analytics
service. User-initiated or user-configured transfers are limited to the Android
speech provider during Push-to-talk when it processes audio off-device, the
user's Stack-chan bridge, a diagnostics share destination selected by the user,
and the configured model host for an optional model download. The final Play
form must apply Google's current collection, sharing, service-provider, and
ephemeral-processing definitions to those paths.

Diagnostics export is local JSON, redacts transcript text, records
model/provisioning state, and uses password placeholders for Wi-Fi provisioning
with `password_redacted=true`.

Data deletion: users can remove saved robot rows and trusted companion rows from
the app UI. Android app uninstall removes app-private local stores. Robot-side
unpairing still requires firmware support and must not be implied in Play copy.

Security practices:

- Local bridge traffic is sent to the endpoint configured by the user. The v1
  LAN bridge is not represented as end-to-end encrypted.
- The app requests offline speech recognition, but the selected Android speech
  service may use network processing under that provider's privacy policy.
- No Play release may claim consumer-ready status until real hardware evidence,
  bundled voice hashes and final policy review are complete.

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
| `RECORD_AUDIO` | Enables explicit Push-to-talk. Denial leaves the turn unsent. The app requests offline recognition, but the configured speech service may process audio off-device; raw audio is not retained or exported in diagnostics. |

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
