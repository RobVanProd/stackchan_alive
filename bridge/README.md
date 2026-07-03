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

The bench output can be sent through `tools/send_bridge_replay_demo.ps1 -TranscriptPath <file>` or pasted into the serial monitor. Later P7 work can replace the deterministic response generator with STT, LLM, memory, and Stackchan Spark TTS while keeping the same frame schema.
