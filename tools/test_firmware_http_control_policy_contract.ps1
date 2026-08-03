$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$policyHeader = Join-Path $repoRoot "src\io\BridgeDebugHttpPolicy.hpp"
$policySource = Join-Path $repoRoot "src\io\BridgeDebugHttpPolicy.cpp"
$mainPath = Join-Path $repoRoot "src\main.cpp"
$platformioPath = Join-Path $repoRoot "platformio.ini"
$issues = [System.Collections.Generic.List[string]]::new()

function Require-PolicyAssertion([bool]$Condition, [string]$Message) {
  if (-not $Condition) { $issues.Add($Message) }
}

function Normalize-CppSource([string]$Text) {
  return ($Text -replace '\s+', '')
}

function Normalize-ExactSource([string]$Text) {
  return (($Text -replace "`r`n", "`n").Trim())
}

function Normalize-PowerShellSource([string]$Text) {
  return ($Text -replace '\s+', '')
}

function Get-NormalizedSourceSha256([string]$Text) {
  $normalized = $Text -replace "`r`n", "`n"
  $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($normalized)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

$headerText = if (Test-Path -LiteralPath $policyHeader -PathType Leaf) {
  Get-Content -LiteralPath $policyHeader -Raw
} else {
  $issues.Add("mandatory-policy: BridgeDebugHttpPolicy.hpp is missing")
  ""
}
$policyText = if (Test-Path -LiteralPath $policySource -PathType Leaf) {
  Get-Content -LiteralPath $policySource -Raw
} else {
  $issues.Add("mandatory-policy: BridgeDebugHttpPolicy.cpp is missing")
  ""
}
$mainText = Get-Content -LiteralPath $mainPath -Raw
$platformioText = Get-Content -LiteralPath $platformioPath -Raw

Require-PolicyAssertion ((Get-NormalizedSourceSha256 $mainText) -ceq
    'A0485CE74DD0AD31B105A61D217D915F2A4294469CEDE9166843A056336958A8') "invariant: src/main.cpp differs from the exact reviewed SEC-002 transformation"
Require-PolicyAssertion ((Get-NormalizedSourceSha256 $headerText) -ceq
    'C3F0D76E398972D43643EB4E2A0C4F1098BEB4E7F810B92E4B0ED190BC0E1D26') "pre-effect: policy header differs from the exact reviewed pure API"
Require-PolicyAssertion ((Get-NormalizedSourceSha256 $policyText) -ceq
    '842B7A69F0946A6481652F5F94C9767190C6270532D69E06F006600E03B4AB30') "pre-effect: policy source differs from the exact reviewed pure call graph"

Require-PolicyAssertion ($policyText.Contains('bool isQueryFamily(') -and
    ([regex]::Matches($policyText, 'isQueryFamily\s*\(')).Count -eq 3 -and
    $policyText.Contains('isQueryFamily(target, targetLength, "/camera-gray.pgm")') -and
    $policyText.Contains('isQueryFamily(target, targetLength, "/vision-target")')) "camera-invariant: only query-bearing camera families may reach camera dispatch"

foreach ($required in @(
  "BridgeDebugHttpDecision", "BridgeDebugHttpRoute", "BridgeDebugHttpDisposition",
  "evaluateBridgeDebugHttpRequestLine", "bridgeDebugHttpMethodName",
  "bridgeDebugHttpRouteName", "bridgeDebugHttpDispositionName"
)) {
  Require-PolicyAssertion ($headerText.Contains($required) -or $policyText.Contains($required)) "mandatory-policy: missing $required"
}

$unsafeAliases = @(
  "/tone", "/speaker-test", "/mic-tone", "/mic-tone-soft", "/mic-tone-tap", "/mic-tone-old",
  "/wake-reset", "/motion-resume", "/motion-on", "/servos-on", "/recover", "/bridge-recover",
  "/wifi-recover", "/reboot", "/restart", "/reset", "/wake.wav", "/wake-pcm.wav"
)
$stopAliases = @("/audio-stop", "/playback-stop", "/motion-stop", "/motion-off", "/servos-off")
foreach ($route in @($unsafeAliases + $stopAliases)) {
  Require-PolicyAssertion $policyText.Contains('"' + $route + '"') "route-exhaustiveness: missing $route"
}

Require-PolicyAssertion $platformioText.Contains("+<io/BridgeDebugHttpPolicy.cpp>") "mandatory-policy: native source filter omits policy implementation"

$pollIndex = $mainText.IndexOf("void pollBridgeDebugServer")
Require-PolicyAssertion ($pollIndex -ge 0) "pre-effect: debug poller missing"
if ($pollIndex -ge 0) {
  $pollEnd = $mainText.IndexOf("void publishFrame", $pollIndex)
  $pollText = if ($pollEnd -gt $pollIndex) { $mainText.Substring($pollIndex, $pollEnd - $pollIndex) } else { $mainText.Substring($pollIndex) }
  $expectedPollText = @'
void pollBridgeDebugServer(uint32_t nowMs) {
#if defined(ARDUINO_ARCH_ESP32)
  if (!gBridgeWiFi.isConnected()) {
    return;
  }
  if (!gBridgeDebugServerStarted) {
    gBridgeDebugServer.begin();
    gBridgeDebugServerStarted = true;
  }

  WiFiClient client = gBridgeDebugServer.available();
  if (!client) {
    return;
  }
  client.setTimeout(100);
  uint32_t requestStartMs = millis();
  char requestLine[256] = {};
  size_t requestLineLen = 0;
  bool firstLineComplete = false;
  bool requestLineOverflow = false;
  bool requestLineInvalid = false;
  bool pendingCarriageReturn = false;
  while (client.connected() && requestStartMs != 0 &&
         millis() - requestStartMs < STACKCHAN_BRIDGE_DEBUG_REQUEST_TIMEOUT_MS) {
    while (client.available() > 0) {
      const char ch = static_cast<char>(client.read());
      if (!firstLineComplete) {
        if (ch == '\n') {
          firstLineComplete = true;
          pendingCarriageReturn = false;
          requestStartMs = 0;
        } else if (pendingCarriageReturn) {
          requestLineInvalid = true;
          pendingCarriageReturn = false;
        } else if (ch == '\r') {
          pendingCarriageReturn = true;
        } else if (static_cast<unsigned char>(ch) < 0x20u ||
                   static_cast<unsigned char>(ch) == 0x7fu) {
          requestLineInvalid = true;
        } else if (requestLineLen < sizeof(requestLine) - 1u) {
          requestLine[requestLineLen++] = ch;
          requestLine[requestLineLen] = '\0';
        } else {
          requestLineOverflow = true;
        }
      }
    }
    if (requestStartMs != 0) {
      delay(1);
    }
  }

  char requestTarget[224] = {};
  const BridgeDebugHttpDecision decision = evaluateBridgeDebugHttpRequestLine(
      requestLine,
      firstLineComplete,
      requestLineOverflow,
      requestLineInvalid,
      requestTarget,
      sizeof(requestTarget));
  gBridgeDebugHttpRequests++;
  switch (decision.disposition) {
    case BridgeDebugHttpDisposition::ServeStatus:
      serveBridgeLeanStatusJson(client, "stackchan.bridge-status.v1", decision);
      return;
    case BridgeDebugHttpDisposition::ServeDebug:
      serveBridgeLeanStatusJson(client, "stackchan.bridge-debug.v1", decision);
      return;
    case BridgeDebugHttpDisposition::EmergencyAudioStop:
      gBridgeDebugHttpEmergencyStops++;
      gBridgeAudioRemoteStopRequests++;
      stopBridgeAudioRuntime(nowMs, BridgeAudioSafetyStopReason::RemoteRequest);
      serveBridgeDebugAdmissionJson(client, 202, "Accepted", true);
      return;
    case BridgeDebugHttpDisposition::EmergencyMotionStop: {
      gBridgeDebugHttpEmergencyStops++;
      BenchControl control;
      control.hasMotionEnable = true;
      control.motionEnabled = false;
      const bool accepted = publishMotionControl(control);
      if (accepted) {
        serveBridgeDebugAdmissionJson(client, 202, "Accepted", true);
      } else {
        serveBridgeDebugAdmissionJson(client, 503, "Service Unavailable", false);
      }
      return;
    }
    case BridgeDebugHttpDisposition::CameraGray:
      gBridgeDebugHttpCameraRoutes++;
#if STACKCHAN_ENABLE_CAMERA_HOST_VISION
      serveCameraGrayFrame(client, requestTarget);
#else
      serveBridgeDebugRejectionJson(client, 404);
#endif
      return;
    case BridgeDebugHttpDisposition::CameraVision:
      gBridgeDebugHttpCameraRoutes++;
#if STACKCHAN_ENABLE_CAMERA_HOST_VISION
      serveCameraVisionTarget(client, requestTarget);
#else
      serveBridgeDebugRejectionJson(client, 404);
#endif
      return;
    case BridgeDebugHttpDisposition::RejectBadRequest:
      gBridgeDebugHttpRejected++;
      serveBridgeDebugRejectionJson(client, decision.statusCode);
      return;
    case BridgeDebugHttpDisposition::RejectForbidden:
      gBridgeDebugHttpRejected++;
      serveBridgeDebugRejectionJson(client, decision.statusCode);
      return;
    case BridgeDebugHttpDisposition::RejectNotFound:
      gBridgeDebugHttpRejected++;
      serveBridgeDebugRejectionJson(client, decision.statusCode);
      return;
    case BridgeDebugHttpDisposition::RejectMethod:
      gBridgeDebugHttpRejected++;
      serveBridgeDebugRejectionJson(client, decision.statusCode);
      return;
    case BridgeDebugHttpDisposition::RejectUriTooLong:
      gBridgeDebugHttpRejected++;
      serveBridgeDebugRejectionJson(client, decision.statusCode);
      return;
    default:
      gBridgeDebugHttpRejected++;
      serveBridgeDebugRejectionJson(client, 400);
      return;
  }
#endif
}
'@
  Require-PolicyAssertion ((Normalize-ExactSource $pollText) -ceq (Normalize-ExactSource $expectedPollText)) "pre-effect: debug dispatcher differs from the frozen byte-exact classify-then-disposition shape"
  $policyIndex = $pollText.IndexOf("evaluateBridgeDebugHttpRequestLine")
  $switchIndex = $pollText.IndexOf("switch (decision.disposition)")
  Require-PolicyAssertion (([regex]::Matches($pollText, "evaluateBridgeDebugHttpRequestLine")).Count -eq 1) "pre-effect: policy must be evaluated exactly once"
  Require-PolicyAssertion ($policyIndex -ge 0 -and $switchIndex -gt $policyIndex) "pre-effect: decision must immediately govern a disposition switch"
  Require-PolicyAssertion ($pollText.Contains('bool requestLineOverflow = false;') -and
      $pollText.Contains('requestLineOverflow = true;') -and
      $pollText.Contains('bool requestLineInvalid = false;') -and
      $pollText.Contains('requestLineInvalid = true;') -and
      $pollText.Contains('bool pendingCarriageReturn = false;') -and
      $pollText.Contains('char requestTarget[224] = {};') -and
      $pollText -match '(?s)evaluateBridgeDebugHttpRequestLine\s*\(\s*requestLine\s*,\s*firstLineComplete\s*,\s*requestLineOverflow\s*,\s*requestLineInvalid\s*,\s*requestTarget\s*,\s*sizeof\s*\(\s*requestTarget\s*\)\s*\)') "pre-effect: bounded listener must report completion/overflow/control bytes and start with an empty target"
  foreach ($disposition in @(
    "ServeStatus", "ServeDebug", "EmergencyAudioStop", "EmergencyMotionStop", "CameraGray",
    "CameraVision", "RejectBadRequest", "RejectForbidden", "RejectNotFound", "RejectMethod",
    "RejectUriTooLong"
  )) {
    Require-PolicyAssertion $pollText.Contains("case BridgeDebugHttpDisposition::$disposition") "pre-effect: missing disposition case $disposition"
  }
  $defaultCaseMatch = [regex]::Match($pollText, '(?s)default\s*:\s*(?<body>gBridgeDebugHttpRejected\+\+\s*;\s*serveBridgeDebugRejectionJson\s*\(\s*client\s*,\s*400\s*\)\s*;\s*return\s*;)\s*\}')
  Require-PolicyAssertion $defaultCaseMatch.Success "pre-effect: disposition switch needs a fixed 400 rejection default"
  foreach ($legacy in @(
    "speakerToneRequest", "micToneSoftRequest", "micToneTapRequest", "micToneOldRequest",
    "wakeResetRequest", "motionEnableRequest", "recoveryRequest", "rebootRequest",
    "serveWakeMwwPcmWav(client)", "suppressWakeMwwDetections"
  )) {
    Require-PolicyAssertion (-not $pollText.Contains($legacy)) "pre-effect: legacy inline mutation remains: $legacy"
  }
  $effectTokens = @("stopBridgeAudioRuntime", "publishMotionControl", "serveCameraGrayFrame",
    "serveCameraVisionTarget", "suppressWakeMwwDetections", "gWakeMwwResetRequested",
    "gBridgeRecovery", "requestBridgeReboot", "serveWakeMwwPcmWav", "gWakeMwwPcmRing",
    "writeWakeWavLe16", "writeWakeWavLe32")
  $caseBodies = @{}
  foreach ($disposition in @("ServeStatus", "ServeDebug", "EmergencyAudioStop", "EmergencyMotionStop",
      "CameraGray", "CameraVision", "RejectBadRequest", "RejectForbidden", "RejectNotFound",
      "RejectMethod", "RejectUriTooLong")) {
    $match = [regex]::Match(
      $pollText,
      '(?s)case\s+BridgeDebugHttpDisposition::' + [regex]::Escape($disposition) +
        '\s*:\s*(?<body>.*?)(?=case\s+BridgeDebugHttpDisposition::|default\s*:|\}\s*$)'
    )
    Require-PolicyAssertion $match.Success "pre-effect: cannot isolate disposition case $disposition"
    $caseBodies[$disposition] = if ($match.Success) { $match.Groups['body'].Value } else { "" }
    Require-PolicyAssertion ($match.Success -and $match.Groups['body'].Value -match '(?s)\breturn\s*;\s*\}?\s*$') "pre-effect: disposition case $disposition can fall through"
  }
  foreach ($rejectCase in @("RejectBadRequest", "RejectForbidden", "RejectNotFound", "RejectMethod", "RejectUriTooLong")) {
    foreach ($effect in $effectTokens) {
      Require-PolicyAssertion (-not $caseBodies[$rejectCase].Contains($effect)) "pre-effect: rejection case $rejectCase contains effect $effect"
    }
  }
  foreach ($readCase in @("ServeStatus", "ServeDebug")) {
    foreach ($effect in $effectTokens) {
      Require-PolicyAssertion (-not $caseBodies[$readCase].Contains($effect)) "pre-effect: status case $readCase contains effect $effect"
    }
  }
  foreach ($closedCase in @("RejectBadRequest", "RejectForbidden", "RejectNotFound", "RejectMethod", "RejectUriTooLong")) {
    $calls = @([regex]::Matches($caseBodies[$closedCase], '(?m)(?<![.>:\w])([A-Za-z_]\w*)\s*\(') | ForEach-Object { $_.Groups[1].Value })
    Require-PolicyAssertion ($calls.Count -eq 1 -and $calls[0] -eq 'serveBridgeDebugRejectionJson' -and
        $caseBodies[$closedCase] -match 'serveBridgeDebugRejectionJson\s*\(\s*client\s*,\s*decision\.statusCode\s*\)') "pre-effect: rejection case $closedCase must contain only the decision-bound fixed rejection helper call"
  }
  foreach ($closedCase in @("ServeStatus", "ServeDebug")) {
    $calls = @([regex]::Matches($caseBodies[$closedCase], '(?m)(?<![.>:\w])([A-Za-z_]\w*)\s*\(') | ForEach-Object { $_.Groups[1].Value })
    Require-PolicyAssertion ($calls.Count -eq 1 -and $calls[0] -eq 'serveBridgeLeanStatusJson') "pre-effect: read case $closedCase must contain only the bounded status helper call"
  }
  Require-PolicyAssertion ($caseBodies['ServeStatus'].Contains('"stackchan.bridge-status.v1"')) "response-telemetry: root is not bound to status schema"
  Require-PolicyAssertion ($caseBodies['ServeDebug'].Contains('"stackchan.bridge-debug.v1"')) "response-telemetry: /debug is not bound to debug schema"
  $audioCalls = @([regex]::Matches($caseBodies['EmergencyAudioStop'], '(?m)(?<![.>:\w])([A-Za-z_]\w*)\s*\(') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'if' })
  Require-PolicyAssertion ($audioCalls.Count -eq 2 -and
      @($audioCalls | Where-Object { $_ -eq 'stopBridgeAudioRuntime' }).Count -eq 1 -and
      @($audioCalls | Where-Object { $_ -eq 'serveBridgeDebugAdmissionJson' }).Count -eq 1) "pre-effect: audio-stop case contains an unapproved helper call"
  $motionCalls = @([regex]::Matches($caseBodies['EmergencyMotionStop'], '(?m)(?<![.>:\w])([A-Za-z_]\w*)\s*\(') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin @('if', 'sizeof') })
  Require-PolicyAssertion ($motionCalls.Count -eq 3 -and
      @($motionCalls | Where-Object { $_ -eq 'publishMotionControl' }).Count -eq 1 -and
      @($motionCalls | Where-Object { $_ -eq 'serveBridgeDebugAdmissionJson' }).Count -eq 2) "pre-effect: motion-stop case contains an unapproved helper call"
  foreach ($cameraCase in @('CameraGray', 'CameraVision')) {
    $expectedCall = if ($cameraCase -eq 'CameraGray') { 'serveCameraGrayFrame' } else { 'serveCameraVisionTarget' }
    $cameraCalls = @([regex]::Matches($caseBodies[$cameraCase], '(?m)(?<![.>:\w])([A-Za-z_]\w*)\s*\(') | ForEach-Object { $_.Groups[1].Value })
    $cameraProfileShape = '(?s)#if\s+STACKCHAN_ENABLE_CAMERA_HOST_VISION\s*' +
      [regex]::Escape($expectedCall) + '\s*\(\s*client\s*,\s*requestTarget\s*\)\s*;\s*#else\s*' +
      'serveBridgeDebugRejectionJson\s*\(\s*client\s*,\s*404\s*\)\s*;\s*#endif'
    Require-PolicyAssertion ($cameraCalls.Count -eq 2 -and
        @($cameraCalls | Where-Object { $_ -eq $expectedCall }).Count -eq 1 -and
        @($cameraCalls | Where-Object { $_ -eq 'serveBridgeDebugRejectionJson' }).Count -eq 1 -and
        $caseBodies[$cameraCase] -match $cameraProfileShape) "pre-effect: camera case $cameraCase lacks the exact enabled-authorized/disabled-404 profile shape"
  }
  Require-PolicyAssertion ($caseBodies["EmergencyAudioStop"].Contains("gBridgeAudioRemoteStopRequests++") -and
      $caseBodies["EmergencyAudioStop"].Contains("stopBridgeAudioRuntime(nowMs, BridgeAudioSafetyStopReason::RemoteRequest)") -and
      $caseBodies["EmergencyAudioStop"] -match '(?s)serveBridgeDebugAdmissionJson\s*\(\s*client\s*,\s*202\s*,\s*"Accepted"\s*,\s*true') "stop-response: audio stop must map directly to 202 accepted:true"
  Require-PolicyAssertion ($caseBodies["EmergencyMotionStop"].Contains("control.hasMotionEnable = true;") -and
      $caseBodies["EmergencyMotionStop"].Contains("control.motionEnabled = false;")) "stop-response: emergency motion action is not bound to disabled state"
  $motionResultBoundByVariable = $caseBodies["EmergencyMotionStop"] -match '(?s)const\s+bool\s+accepted\s*=\s*publishMotionControl\s*\(\s*control\s*\)\s*;.*?if\s*\(\s*accepted\s*\).*?serveBridgeDebugAdmissionJson\s*\(\s*client\s*,\s*202\s*,\s*"Accepted"\s*,\s*true.*?else.*?serveBridgeDebugAdmissionJson\s*\(\s*client\s*,\s*503\s*,\s*"Service Unavailable"\s*,\s*false'
  $motionResultBoundDirectly = $caseBodies["EmergencyMotionStop"] -match '(?s)if\s*\(\s*publishMotionControl\s*\(\s*control\s*\)\s*\).*?serveBridgeDebugAdmissionJson\s*\(\s*client\s*,\s*202\s*,\s*"Accepted"\s*,\s*true.*?else.*?serveBridgeDebugAdmissionJson\s*\(\s*client\s*,\s*503\s*,\s*"Service Unavailable"\s*,\s*false'
  Require-PolicyAssertion ($motionResultBoundByVariable -or $motionResultBoundDirectly) "stop-response: motion publication result must directly govern 202/true versus 503/false"
  Require-PolicyAssertion ($caseBodies["CameraGray"].Contains("serveCameraGrayFrame(client, requestTarget)")) "camera-invariant: gray dispatch not confined to camera case"
  Require-PolicyAssertion ($caseBodies["CameraVision"].Contains("serveCameraVisionTarget(client, requestTarget)")) "camera-invariant: vision dispatch not confined to camera case"

  $betweenPolicyAndSwitch = if ($policyIndex -ge 0 -and $switchIndex -gt $policyIndex) {
    $pollText.Substring($policyIndex, $switchIndex - $policyIndex)
  } else { "" }
  foreach ($effect in $effectTokens) {
    Require-PolicyAssertion (-not $betweenPolicyAndSwitch.Contains($effect)) "pre-effect: effect $effect appears between policy evaluation and disposition switch"
  }
  $betweenCalls = @([regex]::Matches($betweenPolicyAndSwitch, '(?m)(?<![.>:\w])([A-Za-z_]\w*)\s*\(') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'sizeof' })
  Require-PolicyAssertion ($betweenCalls.Count -eq 1 -and $betweenCalls[0] -eq 'evaluateBridgeDebugHttpRequestLine') "pre-effect: an unapproved helper call appears before disposition dispatch"

  $targetRemainder = $pollText
  foreach ($allowedPattern in @(
    'char\s+requestTarget\s*\[\s*224\s*\]\s*=\s*\{\s*\}\s*;',
    'requestTarget\s*,\s*sizeof\s*\(\s*requestTarget\s*\)',
    'serveCameraGrayFrame\s*\(\s*client\s*,\s*requestTarget\s*\)',
    'serveCameraVisionTarget\s*\(\s*client\s*,\s*requestTarget\s*\)'
  )) { $targetRemainder = [regex]::Replace($targetRemainder, $allowedPattern, "") }
  Require-PolicyAssertion (-not $targetRemainder.Contains("requestTarget")) "non-disclosure: requestTarget has a use outside bounded buffer/evaluator/camera dispatch"
  $lineRemainder = $pollText
  foreach ($allowedPattern in @(
    'char\s+requestLine\s*\[\s*256\s*\]\s*=\s*\{\s*\}\s*;',
    'sizeof\s*\(\s*requestLine\s*\)',
    'requestLine\s*\[\s*requestLineLen\+\+\s*\]\s*=\s*ch\s*;',
    'requestLine\s*\[\s*requestLineLen\s*\]\s*=\s*''\\0''\s*;',
    'evaluateBridgeDebugHttpRequestLine\s*\(\s*requestLine\s*,'
  )) { $lineRemainder = [regex]::Replace($lineRemainder, $allowedPattern, "") }
  Require-PolicyAssertion (-not ($lineRemainder -match '\brequestLine\b')) "non-disclosure: requestLine has a use outside bounded capture/evaluator"
  Require-PolicyAssertion (-not ($pollText -match '(?im)^[^\r\n]*(?:Serial\.(?:print|printf)|append|client\.(?:print|printf|write)|log)[^\r\n]*(?:requestTarget|requestLine)[^\r\n]*$')) "non-disclosure: raw request reaches a response/log sink"
  Require-PolicyAssertion (-not ($pollText -match '(?im)^[^\r\n]*(?:requestTarget|requestLine)[^\r\n]*(?:Serial\.(?:print|printf)|append|client\.(?:print|printf|write)|log)[^\r\n]*$')) "non-disclosure: raw request precedes a response/log sink"
  $conditionalLines = @([regex]::Matches($pollText, '(?m)^\s*#(?:if|ifdef|ifndef|elif|else)\b[^\r\n]*') | ForEach-Object { $_.Value.Trim() })
  Require-PolicyAssertion ($conditionalLines.Count -eq 5 -and
      @($conditionalLines | Where-Object { $_ -eq '#if defined(ARDUINO_ARCH_ESP32)' }).Count -eq 1 -and
      @($conditionalLines | Where-Object { $_ -eq '#if STACKCHAN_ENABLE_CAMERA_HOST_VISION' }).Count -eq 2 -and
      @($conditionalLines | Where-Object { $_ -eq '#else' }).Count -eq 2) "profile: conditional policy/effect bypass exists in debug poller"
}

foreach ($required in @('debug_http_control_policy', 'emergency_stop_only',
  'debug_request_route', 'debug_request_method', 'debug_request_result', 'control_disabled')) {
  Require-PolicyAssertion $mainText.Contains($required) "response-telemetry: missing $required"
}
$expectedTelemetrySnippet = @'
  append(",\"debug_http_control_policy\":\"emergency_stop_only\"");
  append(",\"debug_request_method\":\"%s\"", bridgeDebugHttpMethodName(decision.method));
  append(",\"debug_request_route\":\"%s\"", bridgeDebugHttpRouteName(decision.route));
  append(",\"debug_request_result\":\"%s\"", bridgeDebugHttpDispositionName(decision.disposition));
  append(",\"debug_http_requests\":%lu", static_cast<unsigned long>(gBridgeDebugHttpRequests));
  append(",\"debug_http_rejections\":%lu", static_cast<unsigned long>(gBridgeDebugHttpRejected));
  append(",\"debug_http_emergency_stops\":%lu", static_cast<unsigned long>(gBridgeDebugHttpEmergencyStops));
  append(",\"debug_http_camera_routes\":%lu", static_cast<unsigned long>(gBridgeDebugHttpCameraRoutes));
  append(",\"control_disabled\":true");
'@
foreach ($counter in @('gBridgeDebugHttpRequests', 'gBridgeDebugHttpRejected',
    'gBridgeDebugHttpEmergencyStops', 'gBridgeDebugHttpCameraRoutes')) {
  Require-PolicyAssertion (([regex]::Matches($mainText, 'uint32_t\s+' + [regex]::Escape($counter) + '\s*=\s*0\s*;')).Count -eq 1) "response-telemetry: missing single bounded counter declaration $counter"
}
Require-PolicyAssertion (-not $mainText.Contains('append(",\"debug_request\":\"%s\"')) "non-disclosure: raw request target is still emitted"
$allowedPairingAuthorityUses = @(
  'gBridgeEndpointControl.setRequiredPairingCode(pairing.code)',
  'gBridgeEndpointControl.setRequiredPairingCode(ticket.code)',
  'endpointControlConfig.requiredPairingCode = STACKCHAN_PAIRING_SHORT_CODE;'
)
$pairingAuthorityRemainder = $mainText
foreach ($allowedPairingUse in $allowedPairingAuthorityUses) {
  Require-PolicyAssertion (([regex]::Matches($pairingAuthorityRemainder, [regex]::Escape($allowedPairingUse))).Count -eq 1) "non-disclosure: missing or duplicated exact pairing authority consumer $allowedPairingUse"
  $pairingAuthorityRemainder = [regex]::Replace(
    $pairingAuthorityRemainder,
    [regex]::Escape($allowedPairingUse),
    '',
    1)
}
$pairingMacroDefinition = '(?m)^#ifndef STACKCHAN_PAIRING_SHORT_CODE\r?\n#define STACKCHAN_PAIRING_SHORT_CODE ""\r?\n#endif\r?\n?'
Require-PolicyAssertion (([regex]::Matches($pairingAuthorityRemainder, $pairingMacroDefinition)).Count -eq 1) "non-disclosure: pairing macro definition changed or was duplicated"
$pairingAuthorityRemainder = [regex]::Replace($pairingAuthorityRemainder, $pairingMacroDefinition, '', 1)
Require-PolicyAssertion (-not ($pairingAuthorityRemainder -match '(?i)(?:STACKCHAN_PAIRING_SHORT_CODE|\.requiredPairingCode\b|\b(?:pairing|ticket)\.code\b|bridge_endpoint_pairing_code|pairing_code=)')) "non-disclosure: pairing secret source or field has a use outside its three exact bounded authority consumers"
Require-PolicyAssertion (-not ($policyText -match '(?i)printf|Serial\.|iostream|fstream|fprintf|fwrite')) "non-disclosure: pure policy contains an output sink"
Require-PolicyAssertion (-not (($headerText + "`n" + $policyText) -match '(?m)^\s*#\s*(?:if|ifdef|ifndef|elif|else)\b')) "profile: pure policy contains a profile-specific conditional"
$statusHelperStart = $mainText.IndexOf('void serveBridgeLeanStatusJson')
$statusHelperEnd = $mainText.IndexOf('void serveCameraGrayFrame', $statusHelperStart)
$statusHelperText = if ($statusHelperStart -ge 0 -and $statusHelperEnd -gt $statusHelperStart) {
  $mainText.Substring($statusHelperStart, $statusHelperEnd - $statusHelperStart)
} else { "" }
Require-PolicyAssertion ($statusHelperText -match '(?s)^void\s+serveBridgeLeanStatusJson\s*\(\s*WiFiClient&\s+client\s*,\s*const\s+char\*\s+schema\s*,\s*const\s+BridgeDebugHttpDecision&\s+decision\s*\)') "response-telemetry: status helper must accept the evaluated decision by const reference"
Require-PolicyAssertion (([regex]::Matches($statusHelperText, '\bBridgeDebugHttpDecision\b')).Count -eq 1 -and
    -not ($statusHelperText -match '(?m)\bdecision\s*=|\bBridgeDebugHttpDecision\s+decision\b')) "response-telemetry: status helper shadows or assigns the evaluated decision"
Require-PolicyAssertion ((Normalize-ExactSource $statusHelperText).Contains((Normalize-ExactSource $expectedTelemetrySnippet))) "response-telemetry: served bounded status omits evaluated enum fields or counters"
foreach ($effect in @('stopBridgeAudioRuntime', 'publishMotionControl', 'serveCameraGrayFrame',
    'serveCameraVisionTarget', 'suppressWakeMwwDetections', 'requestBridgeReboot',
    'serveWakeMwwPcmWav', 'gWakeMwwPcmRing', 'writeWakeWavLe16', 'writeWakeWavLe32')) {
  Require-PolicyAssertion (-not $statusHelperText.Contains($effect)) "pre-effect: bounded status helper contains effect $effect"
}
Require-PolicyAssertion (-not ($statusHelperText -match '(?m)\b(?:gBridgeRecovery|gWakeMwwResetRequested|gMotionRequested|gAutonomousMotionRequested)\b[^;\r\n]*=')) "pre-effect: bounded status helper assigns authoritative state"
$rejectionHelperIndex = $mainText.IndexOf("void serveBridgeDebugRejectionJson")
$admissionHelperIndex = $mainText.IndexOf("void serveBridgeDebugAdmissionJson")
$pollHelperIndex = $mainText.IndexOf("void pollBridgeDebugServer")
$rejectionHelperText = if ($rejectionHelperIndex -ge 0 -and $admissionHelperIndex -gt $rejectionHelperIndex) {
  $mainText.Substring($rejectionHelperIndex, $admissionHelperIndex - $rejectionHelperIndex)
} else { "" }
$admissionHelperText = if ($admissionHelperIndex -ge 0 -and $pollHelperIndex -gt $admissionHelperIndex) {
  $mainText.Substring($admissionHelperIndex, $pollHelperIndex - $admissionHelperIndex)
} else { "" }
$expectedRejectionHelperText = @'
void serveBridgeDebugRejectionJson(WiFiClient& client, uint16_t statusCode) {
  const char* statusText = "Bad Request";
  switch (statusCode) {
    case 403:
      statusText = "Forbidden";
      break;
    case 404:
      statusText = "Not Found";
      break;
    case 405:
      statusText = "Method Not Allowed";
      break;
    case 414:
      statusText = "URI Too Long";
      break;
    default:
      statusCode = 400;
      break;
  }
  constexpr char body[] = "{\"ok\":false,\"accepted\":false,\"error\":\"control_disabled\"}\n";
  constexpr size_t bodyLength = sizeof(body) - 1u;
  char header[192] = {};
  const int headerLength = snprintf(
      header,
      sizeof(header),
      "HTTP/1.1 %u %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n"
      "Content-Length: %u\r\nConnection: close\r\n\r\n",
      static_cast<unsigned>(statusCode),
      statusText,
      static_cast<unsigned>(bodyLength));
  if (headerLength <= 0 || static_cast<size_t>(headerLength) >= sizeof(header)) {
    client.stop();
    return;
  }
  client.write(reinterpret_cast<const uint8_t*>(header), static_cast<size_t>(headerLength));
  client.write(reinterpret_cast<const uint8_t*>(body), bodyLength);
  delay(1);
  client.stop();
}
'@
$expectedAdmissionHelperText = @'
void serveBridgeDebugAdmissionJson(WiFiClient& client,
                                   uint16_t statusCode,
                                   const char* statusText,
                                   bool accepted) {
  const char* acceptedJson = accepted ? "true" : "false";
  char body[64] = {};
  const int bodyLength = snprintf(
      body,
      sizeof(body),
      "{\"ok\":%s,\"accepted\":%s}\n",
      acceptedJson,
      acceptedJson);
  if (bodyLength <= 0 || static_cast<size_t>(bodyLength) >= sizeof(body)) {
    client.stop();
    return;
  }
  char header[192] = {};
  const int headerLength = snprintf(
      header,
      sizeof(header),
      "HTTP/1.1 %u %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n"
      "Content-Length: %u\r\nConnection: close\r\n\r\n",
      static_cast<unsigned>(statusCode),
      statusText,
      static_cast<unsigned>(bodyLength));
  if (headerLength <= 0 || static_cast<size_t>(headerLength) >= sizeof(header)) {
    client.stop();
    return;
  }
  client.write(reinterpret_cast<const uint8_t*>(header), static_cast<size_t>(headerLength));
  client.write(reinterpret_cast<const uint8_t*>(body), static_cast<size_t>(bodyLength));
  delay(1);
  client.stop();
}
'@
if ([string]::IsNullOrEmpty($rejectionHelperText)) {
  $issues.Add("denial-response: bounded fixed rejection helper missing")
} else {
  Require-PolicyAssertion ((Normalize-ExactSource $rejectionHelperText) -ceq (Normalize-ExactSource $expectedRejectionHelperText)) "denial-response: rejection helper differs from the exact fixed wire shape"
  Require-PolicyAssertion ($rejectionHelperText.Contains('constexpr char body[] = "{\"ok\":false,\"accepted\":false,\"error\":\"control_disabled\"}\n";') -and
      $rejectionHelperText.Contains('char header[192]') -and
      $rejectionHelperText.Contains('Content-Length: %u')) "denial-response: rejection JSON is not the fixed small shape"
  Require-PolicyAssertion (-not ($rejectionHelperText -match '(?i)requestTarget|requestLine|pairing|authorization|credential|gWakeMww|stopped|completed|physical')) "denial-response: rejection helper contains raw/private/effect/completion material"
  Require-PolicyAssertion (-not ($rejectionHelperText -match '\b(?:ESP|M5|WiFi|g[A-Z]\w*)\s*(?:\.|->)')) "denial-response: rejection helper accesses authoritative global hardware/runtime state"
  $rejectionCalls = @([regex]::Matches($rejectionHelperText, '(?m)(?<![.>:\w])([A-Za-z_]\w*)\s*\(') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin @('if', 'switch', 'sizeof') })
  Require-PolicyAssertion (@($rejectionCalls | Where-Object { $_ -notin @('serveBridgeDebugRejectionJson', 'snprintf', 'strlen', 'delay') }).Count -eq 0) "denial-response: rejection helper calls an unapproved helper"
}
if ([string]::IsNullOrEmpty($admissionHelperText)) {
  $issues.Add("stop-response: bounded admission helper missing")
} else {
  Require-PolicyAssertion ((Normalize-ExactSource $admissionHelperText) -ceq (Normalize-ExactSource $expectedAdmissionHelperText)) "stop-response: admission helper differs from the exact accepted-parameter-bound wire shape"
  Require-PolicyAssertion ($admissionHelperText.Contains('char body[64]') -and
      $admissionHelperText.Contains('char header[192]') -and
      $admissionHelperText.Contains('\"accepted\":%s')) "stop-response: admission JSON is not bounded accepted-only shape"
  Require-PolicyAssertion (-not ($admissionHelperText -match '(?i)stopped|motion_disabled|completed|physical|requestTarget|requestLine|pairing|authorization|credential|gWakeMww')) "stop-response: admission helper claims completion or contains raw/private/effect material"
  Require-PolicyAssertion (-not ($admissionHelperText -match '\b(?:ESP|M5|WiFi|g[A-Z]\w*)\s*(?:\.|->)')) "stop-response: admission helper accesses authoritative global hardware/runtime state"
  $admissionCalls = @([regex]::Matches($admissionHelperText, '(?m)(?<![.>:\w])([A-Za-z_]\w*)\s*\(') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin @('if', 'sizeof') })
  Require-PolicyAssertion (@($admissionCalls | Where-Object { $_ -notin @('serveBridgeDebugAdmissionJson', 'snprintf', 'strlen', 'delay') }).Count -eq 0) "stop-response: admission helper calls an unapproved helper"
}
foreach ($requiredInvariant in @(
  '#define STACKCHAN_REMOTE_RECOVERY_ENABLE STACKCHAN_ENABLE_WIFI_BRIDGE',
  'serviceBridgeRecovery(nowMs);', '#define STACKCHAN_OTA_PORT 8790', 'gLanOtaServer.poll('
)) {
  Require-PolicyAssertion $mainText.Contains($requiredInvariant) "invariant: missing autonomous recovery/OTA token $requiredInvariant"
}

function Get-BoundedSourceSection([string]$Text, [string]$StartMarker, [string]$EndMarker) {
  $start = $Text.IndexOf($StartMarker)
  $end = if ($start -ge 0) { $Text.IndexOf($EndMarker, $start + $StartMarker.Length) } else { -1 }
  if ($start -lt 0 -or $end -le $start) { return "" }
  return ($Text.Substring($start, $end - $start) -replace "`r`n", "`n")
}

$frozenPreregCommit = 'd75c62f37f8ff6e1c6cf49bc2c4c01479cd4f02f'
$approvedPackagePrerequisiteCommit = '2ed5bb6ad4755129b61aa0f636f0b654a3493d86'
$approvedImplementationCommit = '4d31de414f5f2279b4c423ac3dfd7e940bb540d9'
& git cat-file -e "$frozenPreregCommit`:src/main.cpp" 2>$null
$frozenCommitAvailable = $LASTEXITCODE -eq 0
Require-PolicyAssertion $frozenCommitAvailable "invariant: frozen preregistration source commit is unavailable"
& git merge-base --is-ancestor $frozenPreregCommit HEAD
$candidateDescendsFromPrereg = $LASTEXITCODE -eq 0
Require-PolicyAssertion $candidateDescendsFromPrereg "invariant: candidate does not descend from frozen preregistration commit"
& git cat-file -e "$approvedPackagePrerequisiteCommit`^{commit}" 2>$null
$packagePrerequisiteAvailable = $LASTEXITCODE -eq 0
Require-PolicyAssertion $packagePrerequisiteAvailable "scope: approved package prerequisite commit is unavailable"
$packagePrerequisiteParent = if ($packagePrerequisiteAvailable) {
  (& git rev-parse "$approvedPackagePrerequisiteCommit`^").Trim()
} else { "" }
Require-PolicyAssertion ($packagePrerequisiteParent -ceq $frozenPreregCommit) "scope: approved package prerequisite does not directly follow preregistration"
$packagePrerequisiteFiles = @(if ($packagePrerequisiteAvailable) {
  & git diff-tree --no-commit-id --name-only -r $approvedPackagePrerequisiteCommit
})
Require-PolicyAssertion ($packagePrerequisiteFiles.Count -eq 1 -and
    $packagePrerequisiteFiles[0] -ceq 'tools/package_release.ps1') "scope: approved package prerequisite changed outside its reviewed file"
& git merge-base --is-ancestor $approvedPackagePrerequisiteCommit HEAD
$candidateDescendsFromPackagePrerequisite = $LASTEXITCODE -eq 0
Require-PolicyAssertion $candidateDescendsFromPackagePrerequisite "scope: candidate does not descend from the approved package prerequisite"
& git cat-file -e "$approvedImplementationCommit`^{commit}" 2>$null
$implementationCommitAvailable = $LASTEXITCODE -eq 0
Require-PolicyAssertion $implementationCommitAvailable "scope: approved implementation commit is unavailable"
$implementationCommitParent = if ($implementationCommitAvailable) {
  (& git rev-parse "$approvedImplementationCommit`^").Trim()
} else { "" }
Require-PolicyAssertion ($implementationCommitParent -ceq $approvedPackagePrerequisiteCommit) "scope: approved implementation does not directly follow the package prerequisite"
& git merge-base --is-ancestor $approvedImplementationCommit HEAD
$candidateDescendsFromImplementation = $LASTEXITCODE -eq 0
Require-PolicyAssertion $candidateDescendsFromImplementation "scope: candidate does not descend from the approved implementation"
$baselineMainText = if ($frozenCommitAvailable) { ((& git show "$frozenPreregCommit`:src/main.cpp") -join "`n") } else { "" }
foreach ($frozenSection in @(
  @{ Start = '#ifndef STACKCHAN_OTA_PORT'; End = '#ifndef STACKCHAN_BASE_USB_POWER_INPUT'; Name = 'OTA port token digest and health configuration' },
  @{ Start = 'void suppressWakeMwwDetections'; End = 'void serveWakeMwwPcmWav'; Name = 'on-device wake capture and gating' },
  @{ Start = 'void serveWakeMwwPcmWav'; End = 'void WakeMwwProbeTask'; Name = 'wake PCM/WAV exporter implementation' },
  @{ Start = 'void WakeMwwProbeTask'; End = 'void ensureWakeSrStarted'; Name = 'on-device wake model task' },
  @{ Start = 'void serviceLanOta'; End = 'void printBridgeOutput'; Name = 'OTA health and polling authority' },
  @{ Start = 'bool publishMotionControl'; End = 'void requestMotionSafetyHold'; Name = 'actuator single-writer publication' },
  @{ Start = 'void updateBridgeNetwork'; End = 'void serveBridgeLeanStatusJson'; Name = 'bridge framing and network-session authority' },
  @{ Start = 'void restartBridgeWiFi'; End = 'void serviceBridgeRecovery'; Name = 'bridge and Wi-Fi recovery effect helpers' },
  @{ Start = 'void serviceBridgeRecovery'; End = 'void handleWiFiProvisioningControl'; Name = 'autonomous offline recovery supervisor' },
  @{ Start = 'void applyMotionControlInput'; End = 'bool shouldSuppressMotionForAudio'; Name = 'actuator command consumer' },
  @{ Start = 'void MotionTask'; End = 'void FaceTask'; Name = 'motion safety task authority' },
  @{ Start = 'void FaceTask'; End = 'void IntentTask'; Name = 'procedural face timing gate' },
  @{ Start = 'void IntentTask'; End = 'void setup()'; Name = 'bridge recovery OTA wake and debug service call sites' },
  @{ Start = 'void setup()'; End = 'void loop()'; Name = 'task creation bridge framing OTA token and actuator setup' }
)) {
  $baselineSection = Get-BoundedSourceSection $baselineMainText $frozenSection.Start $frozenSection.End
  $candidateSection = Get-BoundedSourceSection $mainText $frozenSection.Start $frozenSection.End
  Require-PolicyAssertion (-not [string]::IsNullOrEmpty($baselineSection) -and $candidateSection -ceq $baselineSection) "invariant: changed $($frozenSection.Name) section"
}
Require-PolicyAssertion (([regex]::Matches($mainText, 'LanOtaServer\s+gLanOtaServer\s*\(\s*STACKCHAN_OTA_PORT\s*\)\s*;')).Count -eq 1) "invariant: OTA server construction changed from the frozen configured port"

$baselineCameraFunctionStart = $baselineMainText.IndexOf('bool writeHttpBody')
$candidateCameraFunctionStart = $mainText.IndexOf('bool writeHttpBody')
$cameraProfileMarker = '#if defined(ARDUINO_ARCH_ESP32) && STACKCHAN_ENABLE_CAMERA_HOST_VISION'
$baselineCameraStart = if ($baselineCameraFunctionStart -ge 0) {
  $baselineMainText.LastIndexOf($cameraProfileMarker, $baselineCameraFunctionStart)
} else { -1 }
$candidateCameraStart = if ($candidateCameraFunctionStart -ge 0) {
  $mainText.LastIndexOf($cameraProfileMarker, $candidateCameraFunctionStart)
} else { -1 }
$baselineCameraVisionStart = if ($baselineCameraStart -ge 0) {
  $baselineMainText.IndexOf('void serveCameraVisionTarget', $baselineCameraStart)
} else { -1 }
$candidateCameraVisionStart = if ($candidateCameraStart -ge 0) {
  $mainText.IndexOf('void serveCameraVisionTarget', $candidateCameraStart)
} else { -1 }
$baselineCameraEndMarker = if ($baselineCameraVisionStart -ge 0) {
  $baselineMainText.IndexOf('#endif', $baselineCameraVisionStart)
} else { -1 }
$candidateCameraEndMarker = if ($candidateCameraVisionStart -ge 0) {
  $mainText.IndexOf('#endif', $candidateCameraVisionStart)
} else { -1 }
$baselineCameraEnd = if ($baselineCameraEndMarker -ge 0) {
  $baselineCameraEndMarker + '#endif'.Length
} else { -1 }
$candidateCameraEnd = if ($candidateCameraEndMarker -ge 0) {
  $candidateCameraEndMarker + '#endif'.Length
} else { -1 }
$baselineCameraText = if ($baselineCameraStart -ge 0 -and $baselineCameraEnd -gt $baselineCameraStart) {
  $baselineMainText.Substring($baselineCameraStart, $baselineCameraEnd - $baselineCameraStart)
} else { "" }
$candidateCameraText = if ($candidateCameraStart -ge 0 -and $candidateCameraEnd -gt $candidateCameraStart) {
  $mainText.Substring($candidateCameraStart, $candidateCameraEnd - $candidateCameraStart) -replace "`r`n", "`n"
} else { "" }
Require-PolicyAssertion (-not [string]::IsNullOrEmpty($baselineCameraText) -and
    $candidateCameraText -ceq $baselineCameraText) "camera-invariant: parser authorizer response and capture handlers changed from preregistration"
$debugReachabilityText = $statusHelperText + "`n" + $rejectionHelperText + "`n" +
  $admissionHelperText + "`n" + $candidateCameraText + "`n" + $pollText + "`n" +
  $headerText + "`n" + $policyText
foreach ($pcmToken in @('serveWakeMwwPcmWav', 'gWakeMwwPcmRing', 'writeWakeWavLe16',
    'writeWakeWavLe32')) {
  Require-PolicyAssertion (-not $debugReachabilityText.Contains($pcmToken)) "wake-invariant: debug HTTP classification/response/camera slice can reach PCM/WAV token $pcmToken"
}

$baselinePlatformioText = if ($frozenCommitAvailable) {
  ((& git show "$frozenPreregCommit`:platformio.ini") -join "`n").TrimEnd()
} else { "" }
$baselinePublicReleaseMotion = @'
build_unflags =
  -D STACKCHAN_MOTION_ENABLED_AT_BOOT=0
build_flags =
  ${env:stackchan_release_forensics.build_flags}
  -D STACKCHAN_MOTION_ENABLED_AT_BOOT=1
  -D STACKCHAN_AUTONOMOUS_MOTION_AT_BOOT=1
'@
$candidatePublicReleaseMotion = @'
build_flags =
  ${env:stackchan_release_forensics.build_flags}
  -D STACKCHAN_AUTONOMOUS_MOTION_AT_BOOT=0
'@
$normalizedCandidatePlatformio = $platformioText -replace "`r`n", "`n"
$candidatePublicReleaseBlock = [regex]::Match(
  $normalizedCandidatePlatformio,
  '(?ms)^\[env:stackchan_release_full\]\s*(.*?)(?=^\[env:|\z)').Value
$baselinePublicReleaseBlock = [regex]::Match(
  $baselinePlatformioText,
  '(?ms)^\[env:stackchan_release_full\]\s*(.*?)(?=^\[env:|\z)').Value
Require-PolicyAssertion (([regex]::Matches(
      $candidatePublicReleaseBlock,
      [regex]::Escape($candidatePublicReleaseMotion))).Count -eq 1) "profile: public release no-motion boot stanza is missing or duplicated"
Require-PolicyAssertion (([regex]::Matches(
      $baselinePublicReleaseBlock,
      [regex]::Escape($baselinePublicReleaseMotion))).Count -eq 1) "profile: frozen public release boot-motion stanza is missing or duplicated"
$candidatePlatformioAtFrozenMotionPolicy = $normalizedCandidatePlatformio.Replace(
  $candidatePublicReleaseMotion,
  $baselinePublicReleaseMotion)
$candidatePlatformioWithoutPolicy = ([regex]::Replace(
    $candidatePlatformioAtFrozenMotionPolicy,
    '(?m)^[^\S\r\n]*\+<io/BridgeDebugHttpPolicy\.cpp>[^\S\r\n]*\n?',
    '')).TrimEnd()
Require-PolicyAssertion (-not [string]::IsNullOrEmpty($baselinePlatformioText) -and
    $candidatePlatformioWithoutPolicy -ceq $baselinePlatformioText) "profile: platformio.ini changed beyond the preregistered policy source-filter and exact public no-motion boot stanzas"

$allowedChangedFiles = @(
  'INITIAL_RISK_REGISTER.md', 'PROJECT_STATE.md', 'TASK_LEDGER.md', 'platformio.ini',
  'src/io/BridgeDebugHttpPolicy.hpp', 'src/io/BridgeDebugHttpPolicy.cpp', 'src/main.cpp',
  'test/test_native_logic/test_main.cpp', 'bridge/dashboard_service.py',
  'bridge/test_dashboard_service.py', 'bridge/dashboard/app.js',
  'tools/test_firmware_http_control_policy_contract.ps1',
  'tools/test_stackchan_dashboard_launcher_contract.ps1',
  'tools/camera_follow_wake_validation.ps1',
  'tools/test_camera_follow_wake_validation_contract.ps1',
  'tools/run_full_system_soak_http_motion.ps1',
  'tools/start_warm_rocm_full_system_soak.ps1',
  'tools/test_start_warm_rocm_full_system_soak_contract.ps1',
  'tools/watch_stackchan_wake_test.ps1', 'tools/verify_release_package.ps1',
  'docs/BRIDGE_PROTOCOL.md', 'docs/BRIDGE_DASHBOARD.md', 'docs/ARRIVAL_DAY_RUNBOOK.md'
)
$implementationFiles = @(& git diff --name-only $approvedPackagePrerequisiteCommit $approvedImplementationCommit)
foreach ($implementationFile in @($implementationFiles | Sort-Object -Unique)) {
  Require-PolicyAssertion ($allowedChangedFiles -contains $implementationFile) "scope: approved implementation contains unpreregistered file $implementationFile"
}
foreach ($allowedChangedFile in $allowedChangedFiles) {
  Require-PolicyAssertion ($implementationFiles -contains $allowedChangedFile) "scope: approved implementation is missing reviewed file $allowedChangedFile"
}

$grayStart = $mainText.IndexOf("void serveCameraGrayFrame")
$grayEnd = $mainText.IndexOf("void serveCameraVisionTarget", $grayStart)
$visionEnd = $mainText.IndexOf("#endif", $grayEnd)
if ($grayStart -ge 0 -and $grayEnd -gt $grayStart) {
  $grayText = $mainText.Substring($grayStart, $grayEnd - $grayStart)
  $grayAuthGuard = [regex]::Match($grayText, '(?s)if\s*\(\s*!parseCameraHostPairingCode\s*\(\s*requestTarget\s*,\s*"/camera-gray\.pgm"\s*,\s*pairingCode\s*,\s*sizeof\s*\(\s*pairingCode\s*\)\s*\)\s*\|\|\s*!gBridgeEndpointControl\.authorizesPairedRequest\s*\(\s*pairingCode\s*\)\s*\)\s*\{(?<deny>.*?)\breturn\s*;\s*\}')
  $grayCaptureIndex = $grayText.IndexOf("captureGray160")
  Require-PolicyAssertion ($grayAuthGuard.Success -and $grayCaptureIndex -gt $grayAuthGuard.Index + $grayAuthGuard.Length -and
      $grayAuthGuard.Groups['deny'].Value.Contains('noteHostAuthFailure') -and
      $grayAuthGuard.Groups['deny'].Value.Contains('403') -and
      $grayAuthGuard.Groups['deny'].Value.Contains('pairing_required')) "camera-invariant: gray capture must follow a returning parser/pairing 403 guard with auth accounting"
  Require-PolicyAssertion (([regex]::Matches($grayText, '\brequestTarget\b')).Count -eq 2 -and
      ([regex]::Matches($grayText, '\bpairingCode\b')).Count -eq 4) "camera-invariant: gray raw target/pairing material has a use outside signature/parser/authorizer"
} else { $issues.Add("camera-invariant: gray handler missing") }
if ($grayEnd -ge 0 -and $visionEnd -gt $grayEnd) {
  $visionText = $mainText.Substring($grayEnd, $visionEnd - $grayEnd)
  $visionParseGuard = [regex]::Match($visionText, '(?s)if\s*\(\s*!parseCameraHostVisionTarget\s*\(\s*requestTarget\s*,\s*&target\s*\)\s*\)\s*\{(?<deny>.*?)\breturn\s*;\s*\}')
  $visionAuthGuard = [regex]::Match($visionText, '(?s)if\s*\(\s*!gBridgeEndpointControl\.authorizesPairedRequest\s*\(\s*target\.pairingCode\s*\)\s*\)\s*\{(?<deny>.*?)\breturn\s*;\s*\}')
  $visionLostIndex = $visionText.IndexOf("submitFaceLost")
  $visionFacesIndex = $visionText.IndexOf("submitFaces")
  Require-PolicyAssertion ($visionParseGuard.Success -and
      $visionParseGuard.Groups['deny'].Value.Contains('400') -and
      $visionParseGuard.Groups['deny'].Value.Contains('invalid_target')) "camera-invariant: malformed vision query must retain returning 400 invalid_target response"
  Require-PolicyAssertion ($visionAuthGuard.Success -and
      $visionAuthGuard.Groups['deny'].Value.Contains('noteHostAuthFailure') -and
      $visionAuthGuard.Groups['deny'].Value.Contains('403') -and
      $visionAuthGuard.Groups['deny'].Value.Contains('pairing_required') -and
      $visionLostIndex -gt $visionAuthGuard.Index + $visionAuthGuard.Length -and
      $visionFacesIndex -gt $visionAuthGuard.Index + $visionAuthGuard.Length) "camera-invariant: vision effects must follow a returning pairing 403 guard with auth accounting"
  Require-PolicyAssertion (([regex]::Matches($visionText, '\brequestTarget\b')).Count -eq 2 -and
      ([regex]::Matches($visionText, 'target\.pairingCode')).Count -eq 1) "camera-invariant: vision raw target/pairing material has a use outside signature/parser/authorizer"
} else { $issues.Add("camera-invariant: vision handler missing") }

try {
  Require-PolicyAssertion (-not (Test-Path Env:\PLATFORMIO_BUILD_FLAGS)) "profile: ambient PLATFORMIO_BUILD_FLAGS override is present"
  $config = (& pio project config --json-output | ConvertFrom-Json)
  $wifiEnvironments = @()
  $profileBypasses = @()
  $faceGateViolations = @()
  $publicReleaseFlags = ""
  foreach ($section in $config) {
    $name = [string]$section[0]
    if (-not $name.StartsWith("env:")) { continue }
    $flags = ""
    foreach ($item in $section[1]) {
      if ([string]$item[0] -eq "build_flags") { $flags = @($item[1]) -join "`n" }
    }
    if ($flags -match '(?m)^-D STACKCHAN_ENABLE_WIFI_BRIDGE=1$') {
      $environmentName = $name.Substring(4)
      $wifiEnvironments += $environmentName
      if ($flags -match '(?i)DEBUG_HTTP|HTTP_CONTROL|UNSAFE_CONTROL|BridgeDebugHttp|pollBridgeDebugServer|publishMotionControl|serveWakeMwwPcmWav') {
        $profileBypasses += $environmentName
      }
      $facePeriodMatch = [regex]::Match($flags, '(?m)^-D STACKCHAN_FACE_PERIOD_MS=(\d+)$')
      if ($facePeriodMatch.Success -and [int]$facePeriodMatch.Groups[1].Value -gt 50) {
        $faceGateViolations += $environmentName
      }
    }
    if ($name -eq "env:stackchan_release_full") {
      $publicReleaseFlags = $flags
    }
  }
  Require-PolicyAssertion ($wifiEnvironments.Count -eq 19) "profile: expected 19 effective Wi-Fi environments, found $($wifiEnvironments.Count)"
  Require-PolicyAssertion ($profileBypasses.Count -eq 0) "profile: control-policy bypass flag appears in $($profileBypasses -join ',')"
  Require-PolicyAssertion ($faceGateViolations.Count -eq 0 -and
      (Get-Content -LiteralPath (Join-Path $repoRoot 'src\config\RobotConfig.hpp') -Raw).Contains('#define STACKCHAN_FACE_PERIOD_MS 33')) "invariant: a Wi-Fi profile weakens the strict 50 ms face gate"
  $publicMotionDefinitions = @([regex]::Matches(
      $publicReleaseFlags,
      '(?<!\S)-D\s+STACKCHAN_MOTION_ENABLED_AT_BOOT=(?<value>[^\s]+)'))
  $publicAutonomousDefinitions = @([regex]::Matches(
      $publicReleaseFlags,
      '(?<!\S)-D\s+STACKCHAN_AUTONOMOUS_MOTION_AT_BOOT=(?<value>[^\s]+)'))
  Require-PolicyAssertion ($publicMotionDefinitions.Count -eq 1 -and
      $publicMotionDefinitions[0].Groups['value'].Value -ceq '0' -and
      $publicAutonomousDefinitions.Count -eq 1 -and
      $publicAutonomousDefinitions[0].Groups['value'].Value -ceq '0') "profile: public full release effective configuration is not uniquely motion-off and autonomous-refresh-off at boot"
} catch {
  $issues.Add("profile: PlatformIO effective configuration unavailable: $($_.Exception.GetType().Name)")
}

$toolContracts = @(
  @{ Path = "tools\camera_follow_wake_validation.ps1"; GuardName = 'Assert-EmergencyStopOnlyMotionPolicy'; PolicyReader = 'Invoke-RobotEndpoint'; Refusal = 'motion_resume_unavailable'; Sites = @('Invoke-RobotEndpoint "/motion-resume"', 'New-Item -ItemType Directory -Force -Path $EvidenceRoot') },
  @{ Path = "tools\start_warm_rocm_full_system_soak.ps1"; GuardName = 'Assert-EmergencyStopOnlyMotionPolicy'; PolicyReader = 'Invoke-JsonEndpoint'; Refusal = 'motion_resume_unavailable'; Sites = @('$motionStart = Enable-MotionWithRetry', 'New-Item -ItemType Directory -Force -Path $EvidenceRoot', '.\tools\start_rvc_worker.ps1', '.\tools\start_pc_brain.ps1', '$proc = Start-Process') },
  @{ Path = "tools\run_full_system_soak_http_motion.ps1"; GuardName = 'Assert-EmergencyStopOnlyMotionPolicy'; PolicyReader = 'Invoke-RobotEndpoint'; Refusal = 'motion_resume_unavailable'; Sites = @('Invoke-RobotEndpoint -Path "/motion-resume"', 'New-Item -ItemType Directory -Force -Path $EvidenceRoot') },
  @{ Path = "tools\watch_stackchan_wake_test.ps1"; GuardName = 'Assert-EmergencyStopOnlyWakePolicy'; PolicyReader = 'Invoke-RestMethod'; Refusal = 'wake_control_unavailable'; Sites = @('Invoke-RestMethod -Uri "$BaseUrl/wake-reset"', 'Invoke-RestMethod -Uri "$BaseUrl/mic-tone"', 'New-Item -ItemType Directory -Force -Path $ReportDir') }
)

function Test-AstAncestorType($Node, [type]$AncestorType) {
  $parent = $Node.Parent
  while ($null -ne $parent) {
    if ($parent -is $AncestorType) { return $true }
    $parent = $parent.Parent
  }
  return $false
}

function Test-AstControlFlowAncestor($Node) {
  foreach ($type in @(
    [System.Management.Automation.Language.IfStatementAst],
    [System.Management.Automation.Language.SwitchStatementAst],
    [System.Management.Automation.Language.ForStatementAst],
    [System.Management.Automation.Language.ForEachStatementAst],
    [System.Management.Automation.Language.WhileStatementAst],
    [System.Management.Automation.Language.DoWhileStatementAst],
    [System.Management.Automation.Language.DoUntilStatementAst]
  )) {
    if (Test-AstAncestorType $Node $type) { return $true }
  }
  return $false
}

foreach ($contract in $toolContracts) {
  $path = Join-Path $repoRoot $contract.Path
  $text = Get-Content -LiteralPath $path -Raw
  $guardName = [string]$contract.GuardName
  $refusal = [string]$contract.Refusal
  $expectedGuardText = if ($guardName -eq 'Assert-EmergencyStopOnlyWakePolicy') { @'
function Assert-EmergencyStopOnlyWakePolicy {
  param([string]$Policy)
  throw "wake_control_unavailable: emergency_stop_only permits observation and emergency stops only; wake reset and tone playback are disabled."
}
'@ } else { @'
function Assert-EmergencyStopOnlyMotionPolicy {
  param([string]$Policy)
  throw "motion_resume_unavailable: emergency_stop_only permits emergency stops only; motion resume is disabled."
}
'@ }
  $expectedPolicyHelperText = switch ($contract.Path) {
    'tools\camera_follow_wake_validation.ps1' { @'
function Get-FirmwareHttpControlPolicy {
  $probe = Invoke-RobotEndpoint "/debug" 4
  if ($null -eq $probe -or $probe.ok -ne $true -or $null -eq $probe.json) {
    return "unknown"
  }
  $policy = $probe.json.debug_http_control_policy
  if ($policy -is [string] -and $policy -ceq "emergency_stop_only") {
    return $policy
  }
  return "unknown"
}
'@ }
    'tools\run_full_system_soak_http_motion.ps1' { @'
function Get-FirmwareHttpControlPolicy {
  $probe = Invoke-RobotEndpoint -Path "/debug" -TimeoutSeconds 4
  if ($null -eq $probe -or $probe.ok -ne $true -or $null -eq $probe.json) {
    return "unknown"
  }
  $policy = $probe.json.debug_http_control_policy
  if ($policy -is [string] -and $policy -ceq "emergency_stop_only") {
    return $policy
  }
  return "unknown"
}
'@ }
    'tools\start_warm_rocm_full_system_soak.ps1' { @'
function Get-FirmwareHttpControlPolicy {
  try {
    $probe = Invoke-JsonEndpoint -Path "/debug" -TimeoutSeconds 5
  } catch {
    return "unknown"
  }
  $policy = $probe.debug_http_control_policy
  if ($policy -is [string] -and $policy -ceq "emergency_stop_only") {
    return $policy
  }
  return "unknown"
}
'@ }
    'tools\watch_stackchan_wake_test.ps1' { @'
function Get-FirmwareHttpControlPolicy {
  $policyBaseUrl = $BaseUrl
  if ($policyBaseUrl -eq "") {
    $policyBaseUrl = "http://$DeviceHost`:8789"
  }
  try {
    $probe = Invoke-RestMethod -Uri "$policyBaseUrl/debug" -TimeoutSec 5
  } catch {
    return "unknown"
  }
  $policy = $probe.debug_http_control_policy
  if ($policy -is [string] -and $policy -ceq "emergency_stop_only") {
    return $policy
  }
  return "unknown"
}
'@ }
    default { '' }
  }
  foreach ($required in @("debug_http_control_policy", "emergency_stop_only", "ControlPolicyContractProbe", "Get-FirmwareHttpControlPolicy", $guardName, $refusal)) {
    Require-PolicyAssertion $text.Contains($required) "tool-preflight: $($contract.Path) missing $required"
  }
  Require-PolicyAssertion ($text.Contains('"/debug"') -or $text.Contains('$BaseUrl/debug') -or
      $text.Contains('$policyBaseUrl/debug')) "tool-preflight: $($contract.Path) lacks exact /debug read"

  $tokens = $null
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    Require-PolicyAssertion ($parseErrors.Count -eq 0) "tool-preflight: $($contract.Path) has PowerShell parse errors"
    if ($parseErrors.Count -eq 0) {
    $paramEffects = if ($null -ne $ast.ParamBlock) { @($ast.ParamBlock.FindAll({ param($node)
      $node -is [System.Management.Automation.Language.CommandAst] -or
      $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
      $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
    }, $true)) } else { @() }
    Require-PolicyAssertion ($paramEffects.Count -eq 0) "tool-preflight: $($contract.Path) parameter defaults may not execute commands, member calls, or scriptblocks before refusal"
    $preExecutionShapeSafe = $paramEffects.Count -eq 0
    $traps = @($ast.FindAll({ param($node)
      $node -is [System.Management.Automation.Language.TrapStatementAst]
    }, $true))
    Require-PolicyAssertion ($traps.Count -eq 0) "tool-preflight: $($contract.Path) may not catch refusal with trap"
    $guardFunctions = @($ast.FindAll({ param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $_.Name -eq $guardName })
    Require-PolicyAssertion ($guardFunctions.Count -eq 1) "tool-preflight: $($contract.Path) must define exactly one $guardName"
    $guardIsSafeToRun = $false
    if ($guardFunctions.Count -eq 1) {
      $guardExact = (Normalize-PowerShellSource $guardFunctions[0].Extent.Text) -ceq
        (Normalize-PowerShellSource $expectedGuardText)
      $guardAtRoot = $guardFunctions[0].Parent -is [System.Management.Automation.Language.NamedBlockAst] -and
        $guardFunctions[0].Parent.Parent -eq $ast
      Require-PolicyAssertion $guardExact "tool-preflight: $($contract.Path) refusal guard differs from the exact constant-throw implementation"
      Require-PolicyAssertion $guardAtRoot "tool-preflight: $($contract.Path) refusal guard definition is hidden in a nested scriptblock"
      $guardThrows = @($guardFunctions[0].Body.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.ThrowStatementAst]
      }, $true))
      $guardReturns = @($guardFunctions[0].Body.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.ReturnStatementAst] -or
        $node -is [System.Management.Automation.Language.ExitStatementAst]
      }, $true))
      $guardStatements = @($guardFunctions[0].Body.EndBlock.Statements)
      $guardNestedEffects = @($guardFunctions[0].Body.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -or
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
        $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
      }, $true))
      $guardParamShape = $null -ne $guardFunctions[0].Body.ParamBlock -and
        $guardFunctions[0].Body.ParamBlock.Extent.Text -match '^param\(\s*\[string\]\s*\$Policy\s*\)$'
      $guardBodySafe = $guardParamShape -and $guardThrows.Count -eq 1 -and $guardReturns.Count -eq 0 -and
          $guardStatements.Count -eq 1 -and
          $guardStatements[0] -is [System.Management.Automation.Language.ThrowStatementAst] -and
          $guardNestedEffects.Count -eq 0 -and
          $null -eq $guardFunctions[0].Body.DynamicParamBlock -and
          $null -eq $guardFunctions[0].Body.BeginBlock -and
          $null -eq $guardFunctions[0].Body.ProcessBlock -and
          $guardThrows[0].Extent.Text.Contains($refusal) -and
          $guardFunctions[0].Extent.Text.Contains("emergency_stop_only")
      Require-PolicyAssertion $guardBodySafe "tool-preflight: $($contract.Path) guard body must be exactly one unconditional $refusal throw"
      $guardIsSafeToRun = $preExecutionShapeSafe -and $guardExact -and $guardAtRoot -and $guardBodySafe
    }

    $policyFunctions = @($ast.FindAll({ param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $_.Name -eq 'Get-FirmwareHttpControlPolicy' })
    Require-PolicyAssertion ($policyFunctions.Count -eq 1 -and
        ($policyFunctions[0].Extent.Text.Contains('"/debug"') -or
          $policyFunctions[0].Extent.Text.Contains('$BaseUrl/debug') -or
          $policyFunctions[0].Extent.Text.Contains('$policyBaseUrl/debug')) -and
        $policyFunctions[0].Extent.Text.Contains('debug_http_control_policy')) "tool-preflight: $($contract.Path) capability helper must read only the exact /debug field"
    if ($policyFunctions.Count -eq 1) {
      Require-PolicyAssertion ((Normalize-PowerShellSource $policyFunctions[0].Extent.Text) -ceq
          (Normalize-PowerShellSource $expectedPolicyHelperText)) "tool-preflight: $($contract.Path) capability helper differs from its exact fail-closed /debug implementation"
      Require-PolicyAssertion ($policyFunctions[0].Parent -is [System.Management.Automation.Language.NamedBlockAst] -and
          $policyFunctions[0].Parent.Parent -eq $ast) "tool-preflight: $($contract.Path) capability helper definition is hidden in a nested scriptblock"
      $policyCommands = @($policyFunctions[0].Body.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
      }, $true))
      $policyMemberInvocations = @($policyFunctions[0].Body.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
      }, $true))
      Require-PolicyAssertion ($policyCommands.Count -eq 1 -and
          $policyCommands[0].GetCommandName() -eq [string]$contract.PolicyReader -and
          $policyMemberInvocations.Count -eq 0) "tool-preflight: $($contract.Path) capability helper contains an operation other than its exact /debug reader"
    }

    if ([string]$contract.PolicyReader -ne 'Invoke-RestMethod') {
      $baselineToolText = ((& git show "$frozenPreregCommit`:$($contract.Path.Replace('\', '/'))") -join "`n")
      $baselineToolTokens = $null
      $baselineToolErrors = $null
      $baselineToolAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $baselineToolText,
        [ref]$baselineToolTokens,
        [ref]$baselineToolErrors)
      $baselineReaders = @($baselineToolAst.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
      }, $true) | Where-Object { $_.Name -eq [string]$contract.PolicyReader })
      $candidateReaders = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
      }, $true) | Where-Object { $_.Name -eq [string]$contract.PolicyReader })
      $readerFrozen = $baselineToolErrors.Count -eq 0 -and $baselineReaders.Count -eq 1 -and
        $candidateReaders.Count -eq 1 -and
        (($candidateReaders[0].Extent.Text -replace "`r`n", "`n") -ceq
          ($baselineReaders[0].Extent.Text -replace "`r`n", "`n"))
      Require-PolicyAssertion $readerFrozen "tool-preflight: $($contract.Path) exact /debug wrapper $($contract.PolicyReader) changed from preregistration"
    }

    $topStatements = @($ast.EndBlock.Statements)
    $assignments = @($ast.FindAll({ param($node)
      $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true) | Where-Object {
      $_.Left.Extent.Text -eq '$controlPolicyPreflight' -and
      (Normalize-PowerShellSource $_.Right.Extent.Text) -ceq 'Get-FirmwareHttpControlPolicy' -and
      $_.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and
      $_.Parent.Parent -eq $ast
    })
    $actualGuards = @($ast.FindAll({ param($node)
      $node -is [System.Management.Automation.Language.CommandAst]
    }, $true) | Where-Object {
      $_.GetCommandName() -eq $guardName -and
      (Normalize-PowerShellSource $_.Extent.Text) -ceq ($guardName + '-Policy$controlPolicyPreflight') -and
      -not (Test-AstAncestorType $_ ([System.Management.Automation.Language.FunctionDefinitionAst])) -and
      -not (Test-AstAncestorType $_ ([System.Management.Automation.Language.TryStatementAst])) -and
      -not (Test-AstAncestorType $_ ([System.Management.Automation.Language.ScriptBlockExpressionAst]))
    })
    Require-PolicyAssertion ($assignments.Count -eq 1) "tool-preflight: $($contract.Path) needs one uncaught top-level capability assignment"
    Require-PolicyAssertion ($actualGuards.Count -eq 1) "tool-preflight: $($contract.Path) needs one uncaught top-level guard over the actual capability result"
    $actualGuardOffset = if ($actualGuards.Count -eq 1) { $actualGuards[0].Extent.StartOffset } else { -1 }
    if ($assignments.Count -eq 1 -and $actualGuards.Count -eq 1) {
      Require-PolicyAssertion ($assignments[0].Extent.StartOffset -lt $actualGuardOffset) "tool-preflight: $($contract.Path) capability assignment must precede its guard"
      Require-PolicyAssertion (-not (Test-AstControlFlowAncestor $assignments[0])) "tool-preflight: $($contract.Path) capability assignment must execute unconditionally at script scope"
      Require-PolicyAssertion ($assignments[0].Parent -is [System.Management.Automation.Language.NamedBlockAst] -and
          $assignments[0].Parent.Parent -eq $ast) "tool-preflight: $($contract.Path) capability assignment is hidden in a nested scriptblock"
      $assignmentStatementIndex = [array]::IndexOf($topStatements, $assignments[0])
      if ($contract.Path -eq "tools\watch_stackchan_wake_test.ps1") {
        $guardIfAncestors = [System.Collections.Generic.List[object]]::new()
        $parent = $actualGuards[0].Parent
        while ($null -ne $parent) {
          if ($parent -is [System.Management.Automation.Language.IfStatementAst]) { $guardIfAncestors.Add($parent) }
          $parent = $parent.Parent
        }
        $guardIf = if ($guardIfAncestors.Count -eq 1) { $guardIfAncestors[0] } else { $null }
        $wakeConditionShape = $null -ne $guardIf -and $guardIf.Clauses.Count -eq 1 -and
          (Normalize-PowerShellSource $guardIf.Clauses[0].Item1.Extent.Text) -ceq '-not$SkipReset-or$PlayTone' -and
          (Normalize-PowerShellSource $guardIf.Clauses[0].Item2.Extent.Text) -ceq
            ('{' + $guardName + '-Policy$controlPolicyPreflight}') -and
          $null -eq $guardIf.ElseClause
        $guardStatementIndex = if ($null -ne $guardIf) { [array]::IndexOf($topStatements, $guardIf) } else { -1 }
        Require-PolicyAssertion ($guardIfAncestors.Count -eq 1 -and $wakeConditionShape -and
            $guardIfAncestors[0].Parent -is [System.Management.Automation.Language.NamedBlockAst] -and
            $guardIfAncestors[0].Parent.Parent -eq $ast -and
            $assignmentStatementIndex -ge 0 -and
            $guardStatementIndex -eq ($assignmentStatementIndex + 1) -and
            -not (Test-AstAncestorType $actualGuards[0] ([System.Management.Automation.Language.SwitchStatementAst])) -and
            -not (Test-AstAncestorType $actualGuards[0] ([System.Management.Automation.Language.ForStatementAst])) -and
            -not (Test-AstAncestorType $actualGuards[0] ([System.Management.Automation.Language.ForEachStatementAst])) -and
            -not (Test-AstAncestorType $actualGuards[0] ([System.Management.Automation.Language.WhileStatementAst])) -and
            -not (Test-AstAncestorType $actualGuards[0] ([System.Management.Automation.Language.DoWhileStatementAst])) -and
            -not (Test-AstAncestorType $actualGuards[0] ([System.Management.Automation.Language.DoUntilStatementAst]))) "tool-preflight: wake guard must execute under exactly the reset-or-tone mutation condition"
      } else {
        $guardPipeline = $actualGuards[0].Parent
        $guardStatementIndex = [array]::IndexOf($topStatements, $guardPipeline)
        Require-PolicyAssertion (-not (Test-AstControlFlowAncestor $actualGuards[0]) -and
            $actualGuards[0].Parent -is [System.Management.Automation.Language.PipelineAst] -and
            $actualGuards[0].Parent.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and
            $actualGuards[0].Parent.Parent.Parent -eq $ast -and
            $assignmentStatementIndex -ge 0 -and
            $guardStatementIndex -eq ($assignmentStatementIndex + 1)) "tool-preflight: $($contract.Path) actual guard must execute unconditionally and immediately after capability assignment at script scope"
      }
    }
    foreach ($site in @($contract.Sites)) {
      $siteIndex = $text.IndexOf([string]$site)
      Require-PolicyAssertion ($actualGuardOffset -ge 0 -and $siteIndex -ge 0 -and $actualGuardOffset -lt $siteIndex) "tool-preflight: $($contract.Path) actual guard does not dominate $site"
    }

    $probeBranches = @($ast.FindAll({ param($node)
      $node -is [System.Management.Automation.Language.IfStatementAst]
    }, $true) | Where-Object {
      $_.Extent.Text.Contains('$ControlPolicyContractProbe') -and
      $_.Extent.Text.Contains($guardName) -and
      $_.Extent.Text.Contains('"emergency_stop_only"') -and
      -not (Test-AstAncestorType $_ ([System.Management.Automation.Language.FunctionDefinitionAst])) -and
      -not (Test-AstAncestorType $_ ([System.Management.Automation.Language.TryStatementAst]))
    })
    Require-PolicyAssertion ($probeBranches.Count -eq 1) "tool-preflight: $($contract.Path) needs one uncaught synthetic refusal branch"
    $probeIsSafeToRun = $probeBranches.Count -eq 1 -and $guardIsSafeToRun
    if ($probeIsSafeToRun) {
      $probeOffset = $probeBranches[0].Extent.StartOffset
      $probeShape = '^if\s*\(\s*\$ControlPolicyContractProbe\s*\)\s*\{\s*' +
        [regex]::Escape($guardName) + '\s+-Policy\s+"emergency_stop_only"\s*\}\s*$'
      Require-PolicyAssertion ($probeBranches[0].Extent.Text -match $probeShape) "tool-preflight: $($contract.Path) synthetic branch must contain only the refusal guard"
      $probeAtRoot = $probeBranches[0].Parent -is [System.Management.Automation.Language.NamedBlockAst] -and
        $probeBranches[0].Parent.Parent -eq $ast
      Require-PolicyAssertion $probeAtRoot "tool-preflight: $($contract.Path) synthetic branch is hidden in a nested scriptblock"
      $statementsBeforeProbe = @($ast.EndBlock.Statements | Where-Object {
        $_.Extent.StartOffset -lt $probeOffset
      })
      $unsafeStatementsBeforeProbe = @($statementsBeforeProbe | Where-Object {
        if ($_ -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
          return $_.Name -ne $guardName
        }
        if ($_ -is [System.Management.Automation.Language.AssignmentStatementAst]) {
          return -not ($_.Left.Extent.Text -eq '$ErrorActionPreference' -and
            $_.Right.Extent.Text -match '^["'']Stop["'']$')
        }
        return $true
      })
      Require-PolicyAssertion ($unsafeStatementsBeforeProbe.Count -eq 0) "tool-preflight: $($contract.Path) synthetic refusal is preceded by an executable statement"
      $probeIsSafeToRun = $unsafeStatementsBeforeProbe.Count -eq 0 -and $probeAtRoot -and
        $probeBranches[0].Extent.Text -match $probeShape -and $guardIsSafeToRun
      $actualAssignmentIndex = if ($assignments.Count -eq 1) {
        [array]::IndexOf($topStatements, $assignments[0])
      } else { -1 }
      $probeStatementIndex = [array]::IndexOf($topStatements, $probeBranches[0])
      $prefixStatements = if ($probeStatementIndex -ge 0 -and
          $actualAssignmentIndex -gt ($probeStatementIndex + 1)) {
        @($topStatements[($probeStatementIndex + 1)..($actualAssignmentIndex - 1)])
      } else { @() }
      $expectedPrefixFunctions = if ([string]$contract.PolicyReader -eq 'Invoke-RestMethod') {
        @('Get-FirmwareHttpControlPolicy')
      } else {
        @([string]$contract.PolicyReader, 'Get-FirmwareHttpControlPolicy')
      }
      $actualPrefixFunctionNames = @($prefixStatements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
      } | ForEach-Object { $_.Name })
      $prefixSafe = $probeStatementIndex -ge 0 -and $actualAssignmentIndex -gt $probeStatementIndex -and
        $prefixStatements.Count -eq $expectedPrefixFunctions.Count -and
        @($prefixStatements | Where-Object {
          $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst]
        }).Count -eq 0 -and
        (@($actualPrefixFunctionNames | Sort-Object) -join '|') -ceq
          (@($expectedPrefixFunctions | Sort-Object) -join '|')
      Require-PolicyAssertion $prefixSafe "tool-preflight: $($contract.Path) executable prefix before the actual refusal guard must contain only the frozen endpoint reader and exact policy helper definitions"
      $probeIsSafeToRun = $probeIsSafeToRun -and $prefixSafe
    }
    if ($probeIsSafeToRun) {
      $savedErrorAction = $ErrorActionPreference
      $ErrorActionPreference = "Continue"
      $probeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path -ControlPolicyContractProbe 2>&1 | Out-String
      $probeExit = $LASTEXITCODE
      $ErrorActionPreference = $savedErrorAction
      Require-PolicyAssertion ($probeExit -ne 0 -and $probeOutput.Contains($refusal)) "tool-preflight: $($contract.Path) synthetic probe did not exit with $refusal"
    }
  }

  $refusalCount = ([regex]::Matches($text, [regex]::Escape($refusal))).Count
  Require-PolicyAssertion ($refusalCount -eq 1) "tool-preflight: $($contract.Path) refusal marker must occur exactly once and never be a success label"
  Require-PolicyAssertion (-not ($text -match '(?i)pairing(?:Code|-code|_code)|credential|authorization')) "tool-preflight: $($contract.Path) reads or references forbidden authority material"
  Require-PolicyAssertion (-not ($text -match '"/(?:motion-resume|wake-reset|mic-tone)\?')) "tool-preflight: $($contract.Path) uses query-based mutation authority"
  Require-PolicyAssertion (-not ($text -match '"/(?:motion-on|servos-on|recover|bridge-recover|wifi-recover|reboot|restart|reset)(?:"|\?|\s)')) "tool-preflight: $($contract.Path) contains denied fallback alias"
}

$wakeWatcherText = Get-Content -LiteralPath (Join-Path $repoRoot "tools\watch_stackchan_wake_test.ps1") -Raw
Require-PolicyAssertion $wakeWatcherText.Contains('$BaseUrl/debug') "tool-preflight: wake watcher must read exact /debug"
Require-PolicyAssertion (-not ($wakeWatcherText -match '(?i)(?:BaseUrl|DeviceHost)[^\r\n]{0,80}/status')) "tool-preflight: wake watcher still relies on unknown-route /status fallback"

if ($issues.Count -gt 0) {
  foreach ($issue in $issues) { Write-Output "ASSERTION FAILED: $issue" }
  Write-Output "Firmware HTTP emergency-stop-only policy contract failed with $($issues.Count) named assertion(s)."
  exit 1
}

Write-Host "Firmware HTTP emergency-stop-only policy contract tests passed for all 19 Wi-Fi environments."
