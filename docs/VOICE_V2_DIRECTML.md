# Voice V2 DirectML Runtime

Status: host, wire, firmware, physical speaker, and speech-mouth validation passed. DirectML is
the preferred Windows production runtime; the older warm ROCm worker is retained only as a
rollback until the final combined soak passes.

The Voice V2 path keeps voice conversion on the Windows host, uses the official RVC runtime
with `torch-directml`, and streams completed phrases to the robot instead of waiting for the
entire response to be rendered. Production uses the DirectML worker on port `5059`, the bridge
on `8765`, and a bounded clear local speech fallback if the worker is unavailable. The fallback
is intentionally intelligible rather than voice-matched and is exposed in TTS telemetry; strict
validation can set `STACKCHAN_VOICE_REQUIRE_DIRECTML=1` to reject fallback.

Start or repair the production host path with:

```powershell
.\tools\start_pc_brain_directml.ps1 -RepairMemory -Json
```

The wrapper stops only a verified Stackchan bridge listener, backs up and sanitizes persistent
memory, starts and health-checks DirectML, enables phrase streaming and speaker downlink, waits
for the robot socket and `/debug`, and preserves a runtime evidence packet. It does not flash,
reboot, enable motion, or format storage.

## Performance Gate

The Windows candidate gate is:

- first converted audio after response text in less than `3.0 s`
- complete wake-to-first-audio conversation latency in less than `5.0 s`
- median conversion realtime factor below `1.0`
- exact output accounting with zero truncated phrases
- preserve the full retrieval index (`index_rate=0.62`) and accepted `pm` pitch method

Measured on the Ryzen 7 5700 / Radeon RX 7800 XT host:

| Path | Result |
| --- | ---: |
| Persistent worker startup | `4.65 s` load + `2.92 s` warm-up |
| Warm `Hello` conversion | `0.43 s` |
| Warm 2.34 s phrase | `0.44 s` (`RTF 0.19`) |
| Warm 5.86 s phrase | `0.63 s` (`RTF 0.11`) |
| Median benchmark RTF | `0.22` |
| Complete TTS + RVC client, `Hello` | `1.01 s` |
| Complete TTS + RVC client, 15 words | `1.18 s` |
| Two-phrase streaming rehearsal, first PCM | `1.02 s` |
| Two-phrase streaming rehearsal, complete | `2.14 s` |
| Paced WebSocket transport, first binary audio | `1.22 s` |
| Paced WebSocket transport, complete | `4.80 s` for `5.40 s` audio (`RTF 0.889`) |
| Physical warm-API turns, worst first audio | `3.49 s` conversation / `1.05 s` post-text |
| Physical mouth turn, first audio | `3.53 s` conversation / `1.08 s` post-text |

The passing fixed-corpus report is
`output\voice-lab\directml-rvc-pm-full-index-20260710\benchmark.json`. The earlier RMVPE
comparison is preserved at
`output\voice-lab\directml-rvc-full-index-20260710\benchmark.json`; it missed the median RTF
gate because the official DirectML RMVPE path reloaded its pitch model for each conversion.

## Setup And Benchmark

Run these from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\setup_voice_v2_directml.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_voice_v2_directml_benchmark.ps1 -F0Method pm -OutputDir output\voice-lab\directml-rvc-pm-full-index-latest
```

Start the isolated candidate worker on its lab-only port:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_voice_v2_directml_worker.ps1 -StopExisting -Background -Port 5059 -F0Method pm -IndexRate 0.62
$env:STACKCHAN_RVC_DIRECTML_WORKER_URL = "http://127.0.0.1:5059"
"Hello" | python bridge\rvc_directml_tts_client.py
```

Exercise the actual WebSocket framing and candidate pacing on a temporary localhost bridge:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_voice_v2_wire_benchmark.ps1 -WorkerUrl http://127.0.0.1:5059 -OutputDir output\voice-lab\directml-wire-latest -ChunkBytes 4096 -BinaryDelayMs 70 -TextDelayMs 40
```

The passing wire evidence is
`output\voice-lab\directml-wire-paced-pipelined-70ms-20260710-141700\wire-benchmark.json`.
It uses a producer thread to render the next phrase while the current phrase is paced onto the
wire, defers intermediate short chunks so only the true final chunk receives the long drain
pause, and enables TCP no-delay only in phrase-streaming mode. Requested `80 ms` pacing narrowly
missed the extra whole-wire realtime gate (`1.007x`) under the active Python 3.10 Windows timer
cadence; `70 ms` passed at `0.889x`. The supervised physical runs subsequently confirmed clean,
complete playback with that pacing value and zero forced stops or byte mismatches.

## Robot Speaker Transport

The accepted rollback firmware buffers one complete logical response and rejects a declared
stream larger than `65536` bytes. That is why the observed `71680`-byte response produced
`bridge_downlink_playback_errors=1` and no playback start. The passing `172800`-byte Voice V2
wire corpus would also exceed that sink even though the host and WebSocket transport are exact.

The opt-in `stackchan_voice_v2` firmware environment replaces only that sink behavior. It owns
three stable `4096`-byte PCM buffers and queues each incoming chunk through M5Unified
`playRaw(..., stop_current_sound=false)`. Three buffers are required because M5Unified retains
the current and next buffer without copying them; the third buffer can be filled while those
two are owned by the speaker task. Queue blocking provides bounded backpressure, first playback
can begin on the first chunk, and reply length is no longer limited by a whole-response buffer.
The candidate waits for the speaker channel to drain before releasing the audio hardware, with
a measured forced-stop counter as a fail gate.

Both firmware builds pass:

| Environment | Static RAM | Flash | Result |
| --- | ---: | ---: | --- |
| `stackchan_wake_mww_uplink_servos_m5_voiceout` | `144964` bytes (`44.2%`) | `2656923` bytes | pass |
| `stackchan_voice_v2` | `157252` bytes (`48.0%`) | `2669275` bytes | pass |

The exact `12288`-byte RAM increase is the three-buffer pool. The transport is included in the
currently flashed `stackchan_release_forensics` build. Native firmware tests pass `198/198`,
and the supervised evidence contract proves that a forced stop or any host/robot byte mismatch
fails readiness. The current validated firmware archive is
`output\firmware-candidates\forensics-validated-20260710-204449.zip` (SHA256
`48FF8AFB40906E4CD14E2A8373486FD81DE115656B46AA5A96A50657A0D203BD`); firmware SHA256 is
`32472084CABBFDA57A72B0A9B81D0709F3B3D37EF4410C20756DA6C45607AF24`.

Physical evidence is preserved at
`output\pc-brain\voice-v2-warm-api-supervised-20260710-205818`. Four successful turns passed
all `22/22` checks: `567040` host bytes exactly matched `567040` robot playback bytes across
142 chunks, with zero incomplete phrases, truncation, playback errors, failed `playRaw` calls,
or forced stops. Worst first audio was `3492.31 ms` from conversation start and `1047.52 ms`
after response text. The face remained at 20 FPS with a `29271 us` sampled maximum, VBUS was
`4952 mV`, temperature was `58.5 C`, and motion/rail/torque stayed off.

Speech-mouth evidence is preserved at
`output\pc-brain\voice-v2-mouth-supervised-20260710-210803`. The bridge emitted one mouth frame
for each of 25 streamed PCM chunks, the host and robot reconciled all `97920` bytes, all `22/22`
checks passed, and the operator visually confirmed that Stackchan's mouth moved while speaking.

## Phrase Streaming

Phrase streaming remains disabled in the generic bridge launcher and is explicitly enabled by
the DirectML production wrapper. When enabled, the bridge sends
`audio_stream_start` with unknown totals, emits each completed phrase as soon as conversion
finishes, and sends the exact aggregate byte/chunk totals in `audio_stream_end`. Both firmware
variants parse this protocol shape, but only `stackchan_voice_v2` can physically play a logical
stream larger than `65536` bytes. A phrase with incomplete output is rejected instead of being
silently shortened.

For a repeat supervised validation, connect Stackchan to the PC for flashing and keep the body
clear even though motion remains disabled at boot:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\flash_device.ps1 -Environment stackchan_voice_v2 -Port COM4 -ConfirmServoRisk
$debug = Invoke-RestMethod http://192.168.1.238:8789/debug
$debug | Select-Object speaker_stream_chunked,motion_enabled,servo_rail_enabled,servo_torque_enabled
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_voice_v2_supervised_validation.ps1 -OperatorPresent -ConfirmSpeakerTest
```

Say `Hey Stackchan` once and ask for a two-sentence status update. After the channel drains, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\complete_voice_v2_supervised_validation.ps1 -EvidenceRoot <root-reported-by-start> -ConfirmHeardCleanAudio -ConfirmHeardCompleteReply -Json
```

The checker requires conversation first audio under five seconds, post-text voice first audio
under three seconds, chunked firmware, exact host/robot payload bytes, one `playRaw` success per
accepted playback chunk, zero playback/queue errors, zero forced stops, face frames at or below
`50000 us`, healthy voltage/temperature, safe actuators, and operator confirmation that the
complete reply was clear. It restores the production bridge and port `5055` worker after
capture. If firmware behavior is bad, reconnect USB and flash
`stackchan_wake_mww_uplink_servos_m5_voiceout` with the same servo-risk acknowledgement.

## Fallback Order

DirectML currently meets the Windows gate, so ONNX Runtime/WinML conversion is a documented
fallback rather than the next implementation step. Investigate ONNX/WinML only if sustained
supervised runs fail the latency, stability, or truncation gate. Move to native Linux only if
the Windows DirectML and ONNX/WinML paths both cannot meet those gates on this hardware.
