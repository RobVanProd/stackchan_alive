# Stackchan: Alive Reference Bridge

This directory contains the host-side bridge reference for Stackchan: Alive, the character OS
layer for Stackchan hardware. It is
intentionally small: no cloud dependency, no bundled LLM, and no bundled TTS yet. Its job is to generate and
serve deterministic `stackchan.bridge.v1` control frames that the firmware bridge client
already accepts through the serial bench path and the local LAN scaffold.

Run the built-in demo as bridge JSON:

```powershell
python bridge/reference_bridge.py --format jsonl
```

Run it as firmware bench commands:

```powershell
python bridge/reference_bridge.py --format bench
```

Inspect the deterministic persona prompt and local memory context that the future LAN bridge will pass to the LLM:

```powershell
python bridge/reference_bridge.py --format prompt --name Rob --topic voice --physical-context "room is dark"
python bridge/reference_bridge.py --persona glow --format prompt --name Rob --topic quiet-mode
```

Validate model output against the locked character schema:

```powershell
python bridge/character_harness.py --print-suite
python bridge/character_harness.py --model-profile gemma4-e2b-litert-lm
python bridge/character_harness.py --persona glow --model-profile gemma4-e2b-litert-lm
```

Run adversarial Character Lock cases:

```powershell
python bridge/character_red_team.py --json
python bridge/character_red_team.py --profile gemma4-e2b-gguf --require-runner --json
python bridge/character_red_team.py --persona glow --json
```

The dry run proves the corpus and validator path. A real brain candidate must run the same
suite with a configured local runner and report `summary.gate.ready == true`.

Run the local model wrapper. With no configured runner it returns a deterministic valid
Character Lock response, so bridge demos stay repeatable:

```powershell
python bridge/local_runner.py --list
python bridge/local_runner.py --profile gemma4-e2b-gguf --case greeting --json
python bridge/local_runner.py --profile gemma4-e2b-litert-lm --case picked_up --json
python bridge/local_runner.py --persona glow --profile gemma4-e2b-gguf --case confused --json
```

Run the batch benchmark harness to compare the GGUF, LiteRT-LM, and fallback profiles across
the Character Lock prompt suite:

```powershell
python bridge/model_benchmark.py --json
python bridge/model_benchmark.py --profile gemma4-e2b-litert-lm --require-runner --json
python bridge/model_benchmark.py --persona glow --profile gemma4-e2b-gguf --json
```

The default output goes to `output/model-benchmark/latest/model_benchmark.json` and
`output/model-benchmark/latest/MODEL_BENCHMARK.md`. If every row uses
`deterministic_fallback`, the report is a harness dry run, not real model speed evidence.
The JSON summary also includes `candidate_gate` with threshold settings, per-profile
blockers, `ready_profiles`, and `recommended_profile`; a default brain candidate requires the
full prompt suite, a configured runner for every row, at least 95 percent pass rate, median
latency at or below 2.5 s, and at least 5 approximate tokens per second.

To smoke a real local runner, pass a command or set the profile environment variable. The
prompt is passed on stdin and the command must print one Character Lock JSON object:

```powershell
$env:STACKCHAN_GEMMA4_E2B_GGUF_COMMAND = "ollama run hf.co/google/gemma-4-E2B-it-qat-q4_0-gguf:Q4_0"
python bridge/local_runner.py --profile gemma4-e2b-gguf --case greeting --require-runner --json
```

The bundled `bridge/ollama_stackchan_runner.py` uses Ollama's warm loopback HTTP API by
default. It keeps the model resident, requests bounded JSON output with thinking disabled,
and falls back to the Ollama CLI if the API cannot be reached. The LAN bridge passes the
actual STT transcript through `local_runner.py`; prompt cases supply structure and fallback
examples, not replacement user text. On the validated host this reduced the same prompt from
about 13.7 seconds through the CLI to about 1.0-1.2 seconds through the warm API.

Probe local engine readiness before a benchmark:

```powershell
python bridge/engine_probe.py --json
python bridge/engine_probe.py --run-model-smoke --json
```

The probe writes `output/engine-probe/latest/engine_probe.json` and
`output/engine-probe/latest/ENGINE_PROBE.md`. It checks configured model, STT, and TTS
commands and reports `unconfigured` instead of failing when a new host has no engines
installed yet.

Smoke the LiteRT-LM mobile runner contract without a real model:

```powershell
python bridge/litert_lm_contract_smoke.py --out-dir output/litert-lm-smoke/latest --json
```

It writes `LITERT_LM_SMOKE.md/json` and proves `local_runner.py` can call
`litert_lm_stackchan_wrapper.py`, which then calls `STACKCHAN_LITERT_LM_COMMAND` and returns
validated Character Lock JSON.

Render a validated model-style response through the deterministic bridge:

```powershell
python bridge/reference_bridge.py --format bench --model-response '{"spoken_text":"Looking at you now.","mode":"attend","earcon":"confirm","emotion":{"arousal":0.2,"valence":0.1},"memory_write":{"user.name":"Rob"},"memory_forget":[]}'
```

Render the local runner wrapper through the same bridge frames:

```powershell
python bridge/reference_bridge.py --format bench --runner-profile gemma4-e2b-gguf --runner-case greeting
```

Run the local LAN WebSocket bridge:

```powershell
python bridge/lan_service.py --host 127.0.0.1 --port 8765 --runner-profile gemma4-e2b-gguf
```

Run the socket-level no-hardware smoke report:

```powershell
python bridge/lan_smoke.py --out-dir output/lan-smoke/latest --json
```

It writes `LAN_SMOKE.md/json`, starts a temporary local WebSocket bridge, performs a real
handshake, sends a transcript-backed text turn, then sends a fake mic PCM upload through fake
STT/TTS, validates the binary PCM16 downlink sequence, and checks `thinking-latency` so the
face can show visible thinking before delayed speech finishes. It also exercises the
`endpoint-controls` path for Android/PC companion work: `endpoint_hello`, `claim_brain`,
`settings_get`, `settings_set`, `diagnostics_request`, `trusted_endpoints`, and
`forget_endpoint`.

Audio-only turns can use a local STT command:

```powershell
$env:STACKCHAN_STT_COMMAND = "python path\to\local_stt.py"
python bridge/lan_service.py --host 127.0.0.1 --port 8765 --stt-command "python path\to\local_stt.py"
```

For the PC brain, prefer the repo-local whisper.cpp adapter. Install the local binary/model
once, then use the adapter behind the same bridge contract:

```powershell
.\tools\setup_whisper_cpp.cmd
python bridge/whisper_cpp_stt.py --sample-rate 16000 --json < utterance.s16le
python bridge/lan_service.py --host 127.0.0.1 --port 8765 --stt-command "python bridge\whisper_cpp_stt.py"
```

Windows System.Speech remains available as a fallback adapter at `bridge/windows_speech_stt.py`,
but it should not be treated as the production listener.

The command receives raw signed 16-bit mono PCM on stdin and these environment variables:
`STACKCHAN_AUDIO_SAMPLE_RATE`, `STACKCHAN_AUDIO_FORMAT=s16le_mono`, and
`STACKCHAN_AUDIO_BYTES`. It must print either plain transcript text or JSON with
`transcript`, `text`, or `spoken_text`. If no command is configured, audio-only turns return
`stt_not_implemented`; include `text` or `transcript` on `utterance_end` to bypass STT while
testing.

Response mouth timing can use a local TTS command:

```powershell
$env:STACKCHAN_TTS_COMMAND = "python path\to\local_tts.py"
python bridge/lan_service.py --host 127.0.0.1 --port 8765 --tts-command "python path\to\local_tts.py" --tts-voice rvc-bright
```

The current fast live RVC path is `bridge/rvc_tts_client.py` plus the persistent
`bridge/rvc_worker_service.py`. The client renders bridge response text to a base Windows
System.Speech WAV, sends that WAV to the warm local RVC worker, normalizes the worker output
to capped 16 kHz PCM16, and returns the standard `stackchan.tts-metadata.v1` JSON with
`audio_b64` for robot downlink. The older `bridge/selected_voice_tts.py` adapter is only a
selected sample replay path; it is useful for speaker/downlink smoke checks, but it does not
generate arbitrary speech.

Example warm ROCm RVC bridge start:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_rvc_worker.ps1 -StopExisting -Background -Device cuda:0 -Method pm -Port 5055
$env:STACKCHAN_RVC_WORKER_URL = "http://127.0.0.1:5055"
$env:STACKCHAN_RVC_WORKER_TIMEOUT_SECONDS = "90"
$env:STACKCHAN_RVC_MAX_AUDIO_BYTES = "65536"
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start_pc_brain.ps1 -StopExisting -Background -EnableAudioDownlink -TtsCommand "python bridge\rvc_tts_client.py" -TtsVoice "stackchan-rvc-warm-rocm" -DownlinkBinaryFrameDelayMs 80
```

The physically validated Windows DirectML path is documented in
[`docs/VOICE_V2_DIRECTML.md`](../docs/VOICE_V2_DIRECTML.md). The bridge can opt into phrase
streaming with `-StreamTtsPhrases -TtsPhraseMaxChars 96`. In phrase mode, stream totals are
unknown at `audio_stream_start` and exact at `audio_stream_end`, allowing the first completed
phrase to play without truncating the rest of the response. Each PCM chunk is preceded by one
mouth envelope/viseme frame aggregated from the matching TTS/RVC beat window, so the original
speech-driven mouth behavior remains active during streamed playback.

Long phrase-streaming replies require firmware that reports `speaker_stream_chunked=1`. The
validated `stackchan_release_forensics` build includes that transport and queues each
`4096`-byte PCM chunk through three stable speaker buffers. Supervised physical validation
reconciled `567040` host bytes with `567040` robot bytes over four turns with zero truncation,
playback errors, or forced stops; the separate mouth run reconciled `97920` bytes in 25 chunks
and the operator visually confirmed mouth movement. Do not switch the live bridge during an
active stability soak.

The validated model cache is under `output\voice_sources\stackchan_rvc_base\model\`.
The fallback one-shot CPU adapter remains `bridge/rvc_tts.py` with `.venv-rvc`, device
`cpu:0`, and f0 `harvest`. One-shot ROCm works but is slow for short responses; the warm
worker on `C:\stackchan_rocm_venv` with PyTorch `2.9.1+rocm7.2.1` and device `cuda:0`
is the accelerated path.

The command receives response text on stdin and these environment variables:
`STACKCHAN_TTS_TEXT_BYTES`, `STACKCHAN_TTS_VOICE`, and
`STACKCHAN_TTS_OUTPUT=stackchan.tts-metadata.v1`. It must print metadata JSON with either
`beats` or a speech-envelope-sidecar-style `frames` array. It may also include `audio_b64`.
The TTS adapter canonicalizes `pcm16`, `s16le`, `raw16`, and `pcm_s16le` payloads to
`pcm16`; it also decodes valid uncompressed WAV `audio_b64` to signed 16-bit mono PCM before
downlink. The LAN service uses the beats for `audio` mouth frames and sends playable PCM16 as
`audio_stream_start`, binary WebSocket chunks, and `audio_stream_end`. Firmware currently
parses the stream metadata, copies each accepted chunk into a bounded `BridgeClient` buffer,
exposes the current payload through `BridgeClientOutput`, feeds it to the downlink consumer
for checksum/telemetry validation, accounts received chunk bytes, and rejects mismatched
stream totals. When speaker hardware is enabled, firmware can also hand accepted decoded
PCM16 chunks to the M5 speaker sink. Other formats are transported for validation but are not
played by the downlink sink.

The service accepts `hello`, `endpoint_hello`, `claim_brain`, `release_brain`,
`owner_status`, `trusted_endpoints`, `forget_endpoint`, `settings_get`, `settings_set`,
`diagnostics_request`, `capability_update`, `utterance_start`, `utterance_end`, `heartbeat`,
and `cancel` JSON text frames, plus binary WebSocket PCM frames after `utterance_start`. It
tracks trusted PC/Android endpoints, one active brain owner, safe settings writes, bounded
upload telemetry, and clears raw audio at `utterance_end` or `cancel`. On a transcript-backed
or STT-backed turn, it validates Character
Lock JSON, applies host memory, and streams `thinking`, `response_start`, optional audio
stream chunks, `audio` mouth frames, and `response_end` frames back to the client.

When the service runs with `--turn-log-file output\pc-brain\latest\turns.jsonl`, each completed
turn includes normalized `stackchan.conversation-latency.v1` evidence for capture, STT, brain,
text-ready, first-audio, TTS rendering, audio duration, total time, real-time factor, and
truncation. Summarize the initial conversational gates with:

```powershell
python bridge\conversation_latency_report.py --turn-log output\pc-brain\latest\turns.jsonl --json --require-ready
```

`--require-ready` returns a failure until at least one audio turn is fully measured and every
measured turn has first audio under three seconds, TTS rendering faster than real time, and zero
truncation. These are host/bridge timings; robot playback-completion evidence remains a separate
wire/device gate.

Conversation v2 host-state rehearsal is opt-in and requires confirmable audio downlink:

```powershell
python bridge\lan_service.py --conversation-v2 --tts-command "python bridge\rvc_tts_client.py" --stream-tts-phrases
```

The opt-in session accepts one wake-gated first turn, validates matching firmware
`playback_complete`, then permits a bounded follow-up turn without another wake phrase. Exit
phrases, turn limits, bridge loss, cancellation, TTS failure, and model failure close through a
typed cooldown. This flag does not yet command the firmware to start the follow-up capture and
does not yet provide concurrent in-flight generation cancellation; leave it off for normal v1
operation until those two wire gates pass.

Run the optional local camera detector only with the isolated camera diagnostic firmware:

```powershell
py -3.12 -m venv C:\stackchan_vision_venv
C:\stackchan_vision_venv\Scripts\python.exe -m pip install -r bridge\requirements-vision.txt
C:\stackchan_vision_venv\Scripts\python.exe bridge\vision_service.py --robot-url http://192.168.1.238:8789 --pairing-code 123456
```

The pairing code must match a temporary six-digit code configured on Stackchan. The worker
accepts only a literal private/loopback robot address, processes one 160x120 grayscale frame
in memory, and returns at most four normalized face boxes. It does not persist frames or add
OpenCV to the production bridge runtime. See `docs/LOCAL_VISION.md` for the supervised gate.

Run the no-hardware virtual Stackchan proxy:

```powershell
python bridge/hardware_simulator.py --out-dir output/hardware-sim/latest --json
```

It consumes the same bridge frames as the firmware parser and checks response state, face mode,
speech-envelope frames, binary TTS audio stream accounting, timeout behavior, offline command
fallback, a conversation rehearsal, and a pre-arrival device-shell rehearsal. The conversation
rehearsal simulates virtual wake input, LAN bridge response frames, first-audio latency,
mouth-display activity, and return to `Ready`. The `conversation-tts-downlink` rehearsal adds
a fake WAV-producing local TTS command, verifies bridge-side WAV-to-PCM16 normalization, streams
the decoded PCM16 as binary downlink chunks, and checks virtual M5 speaker handoff counters.
The `conversation-audio-loop` rehearsal adds the fake microphone side: bounded binary PCM
upload, fake local STT, Character Lock/model response, fake WAV TTS, PCM16 downlink, mouth
activity, and virtual speaker handoff.
The device-shell rehearsal simulates virtual
display ticks, label persistence, CoreS3 tap/hold/BtnA/BtnB/BtnC inputs, motion safety
toggles, PCM16 speaker handoff counters, mouth-display activity, and power-cycle recovery. The
audio-downlink scenarios mirror `bridge_downlink_playback_*` telemetry and verify that
unsupported container formats are transported without claiming speaker playback. The
default run also includes `bridge-kill-recovery`: a dropped bridge during an open TTS stream
must produce one offline fallback prompt, reconnect, speak a recovery turn, and return to
`Ready`, plus `offline-command-fallback`: local CoreS3/command-map behavior must request
packaged prompts and animate the mouth without any bridge session. This is a simulation proxy
only; real hardware evidence is still required.

Run the combined pre-arrival simulation check:

```powershell
python bridge/prearrival_sim_check.py --out-dir output/prearrival-sim/latest --json
```

It writes `PREARRIVAL_SIM_CHECK.md/json` with the virtual CoreS3/LAN/audio proxy status, a
nested LAN smoke report, and the engine-readiness status in one place. Simulator and LAN
smoke failures are hard failures; unconfigured model/STT/TTS commands are reported as setup
work until the local engines are installed.

Try the deterministic response planner with user text:

```powershell
python bridge/reference_bridge.py --format bench --user-text "My name is Rob and I picked you up to check the servo voice."
```

Use the LiteRT-LM/mobile adapter when a real low-footprint runner is available:

```powershell
$env:STACKCHAN_LITERT_LM_COMMAND = "python path\to\real_litert_runner.py --model path\to\gemma-4-E2B-it-litert-lm"
$env:STACKCHAN_GEMMA4_E2B_LITERT_COMMAND = "python bridge\litert_lm_stackchan_wrapper.py"
python bridge/local_runner.py --profile gemma4-e2b-litert-lm --require-runner --json
```

The adapter reads the Stackchan prompt on stdin, forwards it to the configured LiteRT-LM
command, skips command logs, validates the first JSON object as Character Lock output, and
prints normalized JSON back to the runner.

Persist the minimal local memory store on the bridge host:

```powershell
python bridge/reference_bridge.py --format prompt --memory-file .stackchan-memory.json --save-memory --user-text "My name is Rob and I want to tune the voice."
```

Reset the store before an audition or demo:

```powershell
python bridge/reference_bridge.py --format prompt --memory-file .stackchan-memory.json --reset-memory
```

The bench output can be sent through `tools/send_bridge_replay_demo.ps1 -TranscriptPath <file>` or pasted into the serial monitor. Later P7 work can replace the deterministic response generator with STT, LLM, memory, and Stackchan Spark TTS while keeping the same frame schema.
