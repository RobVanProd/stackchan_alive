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
- CI runtime smoke: API 35 AOSP ATD install, cold launch, foreground bridge service, and crash check
  against the exact release APK artifact, with SHA-256 binding in aggregate release evidence; this
  remains separate from required target-phone and Play internal-testing evidence.

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

When they are absent, Gradle fails release APK/AAB tasks. A lab or PR build may opt in to
debug signing only by passing `-Pstackchan.allowLabDebugReleaseSigning=true`; that explicit
fallback must not be used for a public GitHub or Play upload.
`tools/check_android_play_release_readiness.ps1` reports this as
`source-ready-pending-upload-signing` until the upload-key environment is configured.
When all four values are present, that checker cryptographically validates the configured material:
it proves the alias is a private-key entry, verifies both passwords through a disposable PKCS#12
copy, requires an RSA key of at least 4096 bits, rejects an Android debug certificate subject,
checks that the certificate is currently valid and expires after `2033-10-22`, and reports the
certificate SHA-256 fingerprint. Passwords are passed to `keytool` only by temporary environment
references, are never written to the report, and the disposable private-key copy is always removed.

The tag workflow reads the same four values from GitHub Actions secrets. The keystore itself
is supplied as base64 in `STACKCHAN_ANDROID_KEYSTORE_B64`; the other three secret names match
the environment variables above. Before building, the tag workflow runs the same cryptographic
readiness checker against those secrets. `tools/export_companion_release_evidence.ps1
-RequireUploadSigning -RequireAndroidEmulatorEvidence` rejects both APK and AAB evidence unless
the `upload-key` profile is recorded and the upload-signed release APK's API 35 launch evidence has
the same SHA-256.

### One-Time Upload Key Provisioning

Create the upload key interactively outside the repository. Do this once, record the owner
identity accurately when `keytool` prompts for the certificate fields, and use unique high-entropy
store and key passwords:

```powershell
$secretDir = Join-Path $HOME "StackchanReleaseSecrets"
$keystore = Join-Path $secretDir "stackchan-upload.jks"
New-Item -ItemType Directory -Force $secretDir | Out-Null
keytool -genkeypair -v `
  -keystore $keystore `
  -storetype JKS `
  -alias stackchan-upload `
  -keyalg RSA `
  -keysize 4096 `
  -validity 10000
keytool -list -v -keystore $keystore -alias stackchan-upload
```

After setting the four local values, run the same release preflight used by CI and compare the
reported certificate SHA-256 fingerprint with the offline key record before building:

```powershell
tools/check_android_play_release_readiness.ps1 -Json
tools/test_android_upload_signing_contract.ps1
```

The first command must report `source-ready`, with `play-upload-signing-environment` set to `pass`.
The second command uses only generated temporary keys to prove that valid material is accepted and
that missing, weak, debug, short-lived, wrong-alias, and wrong-password configurations are rejected.

Before any Play upload, preserve two independent offline media copies of the encrypted JKS and its
password record. Losing the private upload key or its passwords breaks update continuity. Do not
move either copy under this repository or into `output/`.

From an authenticated checkout of the release repository, set the Actions secrets. The
password commands prompt interactively, keeping their values out of the shell command line and
history:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes($keystore)) |
  gh secret set STACKCHAN_ANDROID_KEYSTORE_B64 --app actions
gh secret set STACKCHAN_ANDROID_KEYSTORE_PASSWORD --app actions
gh secret set STACKCHAN_ANDROID_KEY_ALIAS --app actions
gh secret set STACKCHAN_ANDROID_KEY_PASSWORD --app actions
gh secret list --app actions
```

Enter `stackchan-upload` when the alias secret prompts. The two password prompts must receive
the exact store and key passwords created above. `gh secret list` confirms names and update
times only; GitHub never returns secret values. After provisioning, run the read-only
**Companion Signing Readiness** workflow. Its Android job validates the configured keystore and
selected private key without building or publishing an artifact:

```powershell
gh workflow run companion-signing-readiness.yml --ref <release-branch>
gh run watch (gh run list --workflow companion-signing-readiness.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

Then verify the same key locally with the Play-ready build below and retain the APK/AAB signing
evidence before creating a tag.

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

Example lab-only release build:

```powershell
cd companion
.\gradlew.bat "-Pstackchan.allowLabDebugReleaseSigning=true" :app-android:assembleRelease
```

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
- Play policy/data-safety declarations: `docs/ANDROID_PLAY_POLICY_DECLARATIONS.md`
- Play-facing privacy policy: `docs/ANDROID_PLAY_PRIVACY_POLICY.md`
- Static privacy site source: `site/privacy/index.html`
- Canonical privacy URL: https://robvanprod.github.io/stackchan_alive/privacy/
- Public deployment record: `docs/store-assets/play/PRIVACY_POLICY_DEPLOYMENT.json`
- Live deployment verifier: `tools/check_privacy_policy_deployment.ps1 -Json`
- Pages deployment workflow: `.github/workflows/pages.yml`

The canonical URL was first deployed through the isolated `gh-pages` branch so the reviewed
policy could be hosted without merging the broader release-candidate branch. GitHub Pages build
`1094346889` published deployment commit `49cefe092920c0a12da50896356394d380df6904` and the served
bytes match `site/privacy/index.html` at SHA-256
`28d1cca7889f8d95c0587025ee5d46c213a85ac814c538e3c36090b377fd1f47`. After the Pages workflow
lands on `main`, switch the Pages build source to GitHub Actions and refresh the deployment record.

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
It also rejects Play evidence whose uploaded `applicationId`, `versionName`, or `versionCode`
does not match the target-phone APK install report.
The final Companion v1 bundle also rejects Android evidence whose emitted `versionName`
does not match the final release version, whose `applicationId` or `versionCode` does not
match the source Gradle release configuration, or whose Play `releaseAabSha256` is missing
from the companion release evidence artifact list.
The Play evidence checker also rejects packets that are not explicitly marked
`internal-testing-ready`, do not name the uploaded Play Console release/tester group, or
do not include a UTC upload timestamp.

## Manifest And Policy Review

Use `docs/ANDROID_PLAY_POLICY_DECLARATIONS.md` as the source-side draft for the
Play Console Data safety form, foreground-service declaration, and permission
review. Use `docs/ANDROID_PLAY_PRIVACY_POLICY.md` as the source-side privacy
policy review record and `site/privacy/index.html` as the deployable public page.
Before upload, compare both against the exact release build, run
`tools/check_privacy_policy_deployment.ps1 -Json` against the canonical HTTPS URL, and copy
the final reviewed answers into the Play evidence packet. The Android and desktop
apps expose that same canonical URL from their Settings surface.

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
  audio in diagnostics. The app requests offline recognition, but the configured Android
  speech service may process audio off-device under that provider's privacy policy.

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
- `tools/check_privacy_policy_deployment.ps1 -Json` reports
  `privacy-policy-deployment-ready` for the final reviewed policy bytes, and the URL is recorded
  in the Play evidence packet.
- Privacy/data-safety answers are reviewed against actual network, audio, and
  diagnostics behavior.
- Microphone permission copy, denial behavior, and transcript handling are verified from
  the final Android build.
- Play Console internal testing install succeeds from the uploaded AAB.
- `tools/check_android_play_store_evidence.ps1 -Json` reports
  `play-internal-testing-ready`.
