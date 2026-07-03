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
```

Validate model output against the locked character schema:

```powershell
python bridge/character_harness.py --print-suite
python bridge/character_harness.py --model-profile gemma4-e2b-litert-lm
```

Run the local model wrapper. With no configured runner it returns a deterministic valid
Character Lock response, so bridge demos stay repeatable:

```powershell
python bridge/local_runner.py --list
python bridge/local_runner.py --profile gemma4-e2b-gguf --case greeting --json
python bridge/local_runner.py --profile gemma4-e2b-litert-lm --case picked_up --json
```

Run the batch benchmark harness to compare the GGUF, LiteRT-LM, and fallback profiles across
the Character Lock prompt suite:

```powershell
python bridge/model_benchmark.py --json
python bridge/model_benchmark.py --profile gemma4-e2b-litert-lm --require-runner --json
```

The default output goes to `output/model-benchmark/latest/model_benchmark.json` and
`output/model-benchmark/latest/MODEL_BENCHMARK.md`. If every row uses
`deterministic_fallback`, the report is a harness dry run, not real model speed evidence.

To smoke a real local runner, pass a command or set the profile environment variable. The
prompt is passed on stdin and the command must print one Character Lock JSON object:

```powershell
$env:STACKCHAN_GEMMA4_E2B_GGUF_COMMAND = "ollama run hf.co/google/gemma-4-E2B-it-qat-q4_0-gguf:Q4_0"
python bridge/local_runner.py --profile gemma4-e2b-gguf --case greeting --require-runner --json
```

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

Audio-only turns can use a local STT command:

```powershell
$env:STACKCHAN_STT_COMMAND = "python path\to\local_stt.py"
python bridge/lan_service.py --host 127.0.0.1 --port 8765 --stt-command "python path\to\local_stt.py"
```

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

The command receives response text on stdin and these environment variables:
`STACKCHAN_TTS_TEXT_BYTES`, `STACKCHAN_TTS_VOICE`, and
`STACKCHAN_TTS_OUTPUT=stackchan.tts-metadata.v1`. It must print metadata JSON with either
`beats` or a speech-envelope-sidecar-style `frames` array. It may also include `audio_b64`.
The LAN service uses the beats for `audio` mouth frames and sends `audio_b64` as
`audio_stream_start`, binary WebSocket chunks, and `audio_stream_end`. Firmware currently
parses the stream metadata, accounts received chunk bytes, and rejects mismatched stream
totals; speaker playback from downlinked chunks is still future work.

The service accepts `hello`, `utterance_start`, `utterance_end`, `heartbeat`, and `cancel`
JSON text frames, plus binary WebSocket PCM frames after `utterance_start`. It tracks bounded
upload telemetry and clears raw audio at `utterance_end` or `cancel`. On a transcript-backed
or STT-backed turn, it validates Character
Lock JSON, applies host memory, and streams `thinking`, `response_start`, optional audio
stream chunks, `audio` mouth frames, and `response_end` frames back to the client.

Run the no-hardware virtual Stackchan proxy:

```powershell
python bridge/hardware_simulator.py --out-dir output/hardware-sim/latest --json
```

It consumes the same bridge frames as the firmware parser and checks response state, face mode,
speech-envelope frames, binary TTS audio stream accounting, and timeout behavior. This is a
simulation proxy only; real hardware evidence is still required.

Try the deterministic response planner with user text:

```powershell
python bridge/reference_bridge.py --format bench --user-text "My name is Rob and I picked you up to check the servo voice."
```

Persist the minimal local memory store on the bridge host:

```powershell
python bridge/reference_bridge.py --format prompt --memory-file .stackchan-memory.json --save-memory --user-text "My name is Rob and I want to tune the voice."
```

Reset the store before an audition or demo:

```powershell
python bridge/reference_bridge.py --format prompt --memory-file .stackchan-memory.json --reset-memory
```

The bench output can be sent through `tools/send_bridge_replay_demo.ps1 -TranscriptPath <file>` or pasted into the serial monitor. Later P7 work can replace the deterministic response generator with STT, LLM, memory, and Stackchan Spark TTS while keeping the same frame schema.
