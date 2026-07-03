# Stackchan Reference Bridge

This directory contains the first host-side reference for the P7 conversation bridge. It is intentionally small: no STT, LLM, TTS, network, or cloud dependency yet. Its job is to generate deterministic `stackchan.bridge.v1` control frames that the firmware bridge client already accepts through the serial bench path.

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

Render a validated model-style response through the deterministic bridge:

```powershell
python bridge/reference_bridge.py --format bench --model-response '{"spoken_text":"Looking at you now.","mode":"attend","earcon":"confirm","emotion":{"arousal":0.2,"valence":0.1},"memory_write":{"user.name":"Rob"},"memory_forget":[]}'
```

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
