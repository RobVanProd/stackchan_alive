# Android Play Release Checklist

This checklist prepares Stackchan Companion for Google Play distribution after the
v1 physical-robot gates pass.

Authoritative Android release guidance:

- Prepare for release: https://developer.android.com/studio/publish/preparing
- Sign your app: https://developer.android.com/studio/publish/app-signing
- Android App Bundles: https://developer.android.com/guide/app-bundle
- Upload to Play Console: https://developer.android.com/studio/publish/upload-bundle

## Current Release Position

- Application ID: `dev.stackchan.companion`
- App name: `Stackchan Companion`
- Version: `1.0.0`
- Version code: `1`
- Minimum SDK: `26`
- Target SDK: `36`
- Release artifact for Google Play: `app-android-release.aab`
- Lab install artifact for arrival-day testing: `app-android-release.apk`

Google Play requires Android App Bundles for new apps and requires Play App Signing.
APKs remain useful for direct lab installation and robot-arrival testing,
but the Play Console upload target is the release AAB.

## Signing

Do not commit keystores, passwords, upload certificates, or Play service account
credentials.

The Android release build uses production upload-key signing when all of these
Gradle properties or environment variables are present:

- `STACKCHAN_ANDROID_KEYSTORE`
- `STACKCHAN_ANDROID_KEYSTORE_PASSWORD`
- `STACKCHAN_ANDROID_KEY_ALIAS`
- `STACKCHAN_ANDROID_KEY_PASSWORD`

When they are absent, Gradle falls back to the Android debug signing config so the
CI/lab release APK remains installable before Play credentials exist. That fallback
is for testing only and must not be used for a public Play upload.
`tools/check_android_play_release_readiness.ps1` reports this as
`source-ready-pending-upload-signing` until the upload-key environment is configured.

Example local Play-ready build:

```powershell
$env:STACKCHAN_ANDROID_KEYSTORE = "C:\secure\stackchan-upload.jks"
$env:STACKCHAN_ANDROID_KEYSTORE_PASSWORD = "<store-password>"
$env:STACKCHAN_ANDROID_KEY_ALIAS = "stackchan-upload"
$env:STACKCHAN_ANDROID_KEY_PASSWORD = "<key-password>"
cd companion
.\gradlew.bat :app-android:bundleRelease :app-android:assembleRelease
```

Expected outputs:

- `companion/app-android/build/outputs/bundle/release/app-android-release.aab`
- `companion/app-android/build/outputs/apk/release/app-android-release.apk`

## Store Listing Assets

Prepared source-controlled assets:

- Launcher icon: `companion/app-android/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`
- Round launcher icon: `companion/app-android/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml`
- Foreground icon vector: `companion/app-android/src/main/res/drawable/ic_launcher_foreground.xml`
- Monochrome icon vector: `companion/app-android/src/main/res/drawable/ic_launcher_monochrome.xml`
- Play high-resolution icon: `docs/store-assets/play/icon-512.png`
- Play feature graphic: `docs/store-assets/play/feature-graphic-1024x500.png`
- Final screenshot capture plan: `docs/store-assets/play/SCREENSHOT_CAPTURE_PLAN.md`
- Listing metadata: `fastlane/metadata/android/en-US/`
- Play policy/data-safety declaration draft: `docs/ANDROID_PLAY_POLICY_DECLARATIONS.md`
- Play-facing privacy policy draft: `docs/ANDROID_PLAY_PRIVACY_POLICY.md`

Screenshots still need to be captured from the final phone build after physical
robot validation, because the store screenshots should show a real connected
session rather than a simulated dashboard.
The Play listing requires at least two phone screenshots before store submission; v1 should
capture four final-build shots covering setup/pairing, live dashboard, Brain/model controls,
and persona/diagnostics support.

Create the Play evidence packet before uploading, then fill it after the internal
testing release is available:

```powershell
tools/check_android_play_store_evidence.cmd -EvidenceRoot output/android-play-store/latest -WriteTemplate
```

After uploading the AAB to Play Console, installing from the internal testing
track, and adding screenshots, set the evidence packet status to
`internal-testing-ready`, record the Play Console release name, internal tester group,
and `uploadedAtUtc` timestamp for that exact upload, then run:

```powershell
tools/check_android_play_store_evidence.cmd -EvidenceRoot output/android-play-store/latest -Json
```

The generated Play evidence-check JSON includes the reviewed `sourceCommit`. The final
Android v1 bundle rejects Play evidence if that commit does not match the installed APK,
hardware evidence checker outputs, and `ANDROID_V1_EVIDENCE_BUNDLE.json` source commit.
It also rejects Play evidence whose uploaded `versionName` or `versionCode` does not
match the target-phone APK install report.
The final Companion v1 bundle also rejects Android evidence whose emitted `versionName`
does not match the final release version, whose `versionCode` does not match the source
Gradle release configuration, or whose Play `releaseAabSha256` is missing from the
companion release evidence artifact list.
The Play evidence checker also rejects packets that are not explicitly marked
`internal-testing-ready`, do not name the uploaded Play Console release/tester group, or
do not include a UTC upload timestamp.

## Manifest And Policy Review

Use `docs/ANDROID_PLAY_POLICY_DECLARATIONS.md` as the source-side draft for the
Play Console Data safety form, foreground-service declaration, and permission
review. Use `docs/ANDROID_PLAY_PRIVACY_POLICY.md` as the source-side privacy
policy page content. Before upload, compare both documents against the exact
release build, publish the privacy policy at the final URL, and copy the final
reviewed answers into the Play evidence packet.

Before upload, confirm that each Android permission maps to an app behavior visible
in the release:

- `INTERNET`: local bridge server and endpoint communication.
- `ACCESS_NETWORK_STATE`: dashboard network/bridge state.
- `CHANGE_WIFI_MULTICAST_STATE`: mDNS/UDP discovery.
- `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_CONNECTED_DEVICE`: long-running local
  robot bridge.
- `POST_NOTIFICATIONS`: foreground service status notification on modern Android.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and `WAKE_LOCK`: screen-off robot bridge
  reliability test path.
- `RECORD_AUDIO`: explicit Push-to-talk action on the Talk screen. The app sends the
  recognized transcript through the local robot bridge and does not export raw microphone
  audio in diagnostics.

If a Play policy declaration is required for foreground service or battery
optimization behavior, use the physical-test evidence and Android test plan as the
supporting explanation.

## Required Pre-Launch Gates

Do not promote the app beyond internal testing until these are complete:

- `tools/check_companion_v1_readiness.ps1 -Json` reports 0 failures.
- Physical robot validation is complete.
- CI release evidence includes a release AAB, release APK, desktop artifacts, and
  verified signing evidence.
- Physical robot connected-session evidence is captured.
- Android screen-off bridge soak evidence is captured.
- Store screenshots are captured from the final Android build.
- The privacy policy is hosted from the final reviewed
  `docs/ANDROID_PLAY_PRIVACY_POLICY.md` content and the URL is recorded in the
  Play evidence packet.
- Privacy/data-safety answers are reviewed against actual network, audio, and
  diagnostics behavior.
- Microphone permission copy, denial behavior, and transcript handling are verified from
  the final Android build.
- Play Console internal testing install succeeds from the uploaded AAB.
- `tools/check_android_play_store_evidence.ps1 -Json` reports
  `play-internal-testing-ready`.
