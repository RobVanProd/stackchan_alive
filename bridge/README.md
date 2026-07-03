# Stackchan Reference Bridge

This directory contains the first host-side reference for the P7 conversation bridge. It is
intentionally small: no STT, LLM, TTS, or cloud dependency yet. Its job is to generate and
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

The service accepts `hello`, `utterance_start`, `utterance_end`, `heartbeat`, and `cancel`
JSON text frames, plus binary WebSocket PCM frames after `utterance_start`. It tracks bounded
upload telemetry and clears raw audio at `utterance_end`. Until real STT lands, audio-only
turns return `stt_not_implemented`; include `text` or `transcript` on `utterance_end` to drive
the runner path while testing binary upload. On a transcript-backed turn, it validates Character
Lock JSON, applies host memory, and streams `thinking`, `response_start`, `audio`, and
`response_end` frames back to the client.

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
