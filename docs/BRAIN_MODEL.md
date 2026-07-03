# Stackchan Brain Model Harness

P7 uses a small local conversational model behind the bridge, not on the M5 CoreS3. The firmware stays deterministic and real-time; the host bridge owns model inference, character validation, memory policy, and TTS planning.

## Recommended Model Targets

Primary development target:

- `google/gemma-4-E2B-it-qat-q4_0-gguf`
- Runtime: llama.cpp, Ollama, LM Studio, or another GGUF runner.
- Why: smallest current Gemma 4 instruction-tuned QAT GGUF target, native system-prompt support, structured output compatibility, and fast enough to iterate on a Mac Mini or desktop-class host.

Mobile / low-footprint target:

- `litert-community/gemma-4-E2B-it-litert-lm`
- Runtime: LiteRT-LM.
- Why: mobile package for Android, iOS, desktop, IoT, and web. Google describes LiteRT-LM as the optimized edge path for Gemma 4, with CPU/GPU/NPU-oriented backends and lower active memory pressure for text workloads.

Fallback target if E2B fails the character harness:

- `google/gemma-4-E4B-it-qat-q4_0-gguf`
- Use only if E2B cannot stay in character, follow the JSON schema, or keep enough context for the bridge loop.

Source links checked on 2026-07-03:

- Google Gemma 4 overview: https://ai.google.dev/gemma/docs/core
- Google Gemma 4 E2B QAT GGUF: https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf
- LiteRT-LM Gemma 4 E2B package: https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm
- LiteRT-LM performance and memory notes: https://developers.googleblog.com/blazing-fast-on-device-genai-with-litert-lm/

## Decision Rule

Do not fine-tune first. Start with prompting plus the bridge validator. Fine-tuning or LoRA comes later only after failed harness cases prove that prompt and validator controls are not enough.

The first pass measures:

- character-lock compliance
- strict JSON output
- useful `mode` and `earcon` choices
- memory-write safety
- malformed-output recovery
- approximate tokens per second when a local runner command is supplied

## Harness Contract

The harness lives at `bridge/character_harness.py`. It is intentionally runtime-agnostic:

```powershell
python bridge/character_harness.py --print-suite
python bridge/character_harness.py --response '{"spoken_text":"Happy signal detected.","mode":"happy","earcon":"happy","emotion":{"arousal":0.2,"valence":0.3},"memory_write":{},"memory_forget":[]}'
python bridge/character_harness.py --model-profile gemma4-e2b-gguf
```

Optional local model command smoke:

```powershell
python bridge/character_harness.py --model-profile gemma4-e2b-gguf --model-command "ollama run hf.co/google/gemma-4-E2B-it-qat-q4_0-gguf:Q4_0"
```

The command receives the prompt on stdin and must print one JSON object. This lets the same harness test Ollama, llama.cpp wrappers, and a future LiteRT-LM wrapper without changing the bridge validator.

## Local Runner Wrapper

The first P7 runner wrapper lives at `bridge/local_runner.py`. It keeps the primary GGUF
target and the mobile LiteRT-LM target visible behind the same prompt suite:

```powershell
python bridge/local_runner.py --list
python bridge/local_runner.py --profile gemma4-e2b-gguf --case greeting --json
python bridge/local_runner.py --profile gemma4-e2b-litert-lm --case picked_up --json
```

No runner command is required for deterministic bridge demos. If neither a command argument
nor an environment variable is set, the wrapper emits a fixed valid Character Lock response
for the selected prompt case. That fallback is only a bridge/harness stabilizer; it is not a
model benchmark.

Use one of these command sources to run a real local model:

- `--command "<runner command>"`
- `STACKCHAN_GEMMA4_E2B_GGUF_COMMAND`
- `STACKCHAN_GEMMA4_E2B_LITERT_COMMAND`
- `STACKCHAN_GEMMA4_E4B_GGUF_COMMAND`
- generic fallback: `STACKCHAN_MODEL_COMMAND`

Example GGUF smoke:

```powershell
$env:STACKCHAN_GEMMA4_E2B_GGUF_COMMAND = "ollama run hf.co/google/gemma-4-E2B-it-qat-q4_0-gguf:Q4_0"
python bridge/local_runner.py --profile gemma4-e2b-gguf --case greeting --require-runner --json
```

Example LiteRT-LM/mobile smoke:

```powershell
$env:STACKCHAN_LITERT_LM_COMMAND = "python path\to\real_litert_runner.py --model path\to\gemma-4-E2B-it-litert-lm"
$env:STACKCHAN_GEMMA4_E2B_LITERT_COMMAND = "python bridge\litert_lm_stackchan_wrapper.py"
python bridge/local_runner.py --profile gemma4-e2b-litert-lm --case greeting --require-runner --json
```

Run the deterministic LiteRT-LM contract smoke before installing the real mobile runtime:

```powershell
.\tools\run_litert_lm_smoke.cmd -Json
```

It writes `output/litert-lm-smoke/latest/LITERT_LM_SMOKE.md/json` and proves the two-layer
mobile path is wired correctly: `local_runner.py` -> `litert_lm_stackchan_wrapper.py` ->
`STACKCHAN_LITERT_LM_COMMAND`. This is setup evidence only, not real model speed evidence.

`bridge/litert_lm_stackchan_wrapper.py` is the stable low-footprint runner boundary. It reads
the Stackchan Character Lock prompt on stdin, runs `STACKCHAN_LITERT_LM_COMMAND` or
`--command` with that prompt on stdin, skips non-JSON logs, validates the first real JSON
object with `bridge/character_harness.py`, and prints only normalized Character Lock JSON for
`bridge/local_runner.py`.

The runner result records validation output, elapsed milliseconds, and approximate tokens per
second whenever a configured command is used. The same wrapper can feed device frames through
the reference bridge:

```powershell
python bridge/reference_bridge.py --format bench --runner-profile gemma4-e2b-gguf --runner-case greeting
```

## Engine Readiness Probe

Use `bridge/engine_probe.py` before a full benchmark when setting up a new host. It checks
which runner tools are on `PATH`, whether model/STT/TTS commands are configured, and whether
the configured engines can run a minimal smoke pass:

```powershell
.\tools\run_engine_probe.cmd -Json
.\tools\run_engine_probe.cmd -RunModelSmoke -Json
python bridge/engine_probe.py --profile gemma4-e2b-litert-lm --run-model-smoke --json
```

The probe writes:

- `output/engine-probe/latest/engine_probe.json`
- `output/engine-probe/latest/ENGINE_PROBE.md`

GitHub Actions also runs the probe in the `bridge-tests` job and uploads the report as the
`engine-probe` artifact on each PR/push.

GitHub Actions also runs `bridge/litert_lm_contract_smoke.py` and uploads the
`litert-lm-contract-smoke` artifact so the mobile runner contract stays healthy even before
the real LiteRT-LM engine is available.

`unconfigured` means the bridge software is present but no real local engine command is
available yet. That is useful setup evidence, not model speed evidence. A real P7 candidate
still needs a non-dry-run `bridge/model_benchmark.py --require-runner` report after the
probe shows the intended model/STT/TTS commands are reachable.

## Batch Benchmark Evidence

Use `bridge/model_benchmark.py` to run the Character Lock prompt suite across the configured
model profiles and write repeatable evidence:

```powershell
python bridge/model_benchmark.py --json
python bridge/model_benchmark.py --profile gemma4-e2b-gguf --require-runner --json
python bridge/model_benchmark.py --profile gemma4-e2b-litert-lm --require-runner --json
python bridge/model_benchmark.py --profile gemma4-e2b-gguf --require-runner --max-median-ms 2500 --min-tokens-per-sec 5 --json
```

The harness writes:

- `output/model-benchmark/latest/model_benchmark.json`
- `output/model-benchmark/latest/MODEL_BENCHMARK.md`

When no runner command is configured, the report is marked
`dry-run-no-runner-configured`; that proves the prompt/validator path still works, but it is
not speed evidence. A profile only becomes a real candidate once its rows use a configured
runner command and still pass Character Lock validation.

Each report now includes `summary.candidate_gate` with the selected thresholds, per-profile
blockers, `ready_profiles`, and `recommended_profile`. The default gate requires the full
prompt suite, every row backed by a configured runner, pass rate at or above `0.95`, median
latency at or below `2500` ms, and median throughput at or above `5` approximate tokens per
second. Override those only when recording why the host or demo scenario needs a different
budget:

```powershell
python bridge/model_benchmark.py --profile gemma4-e2b-litert-lm --require-runner --min-pass-rate 0.95 --max-median-ms 2500 --min-tokens-per-sec 5 --json
```

The combined pre-arrival proxy can include the same benchmark gate when the real runner is
available:

```powershell
.\tools\run_prearrival_sim_check.cmd -RunModelBenchmark -Json
```

That writes `output/prearrival-sim/latest/model-benchmark/MODEL_BENCHMARK.md/json` and adds a
`model-benchmark-candidate` gate to `PREARRIVAL_SIM_CHECK.md/json`.

The same path is exposed as a local WebSocket service for P7 LAN-loop testing:

```powershell
python bridge/lan_service.py --host 127.0.0.1 --port 8765 --runner-profile gemma4-e2b-gguf
```

This is still a scaffold, not a complete STT/TTS stack. It accepts wake-gated control frames
and runs the runner/validator/memory path on `utterance_end`. It also accepts bounded binary
PCM uploads after `utterance_start`, can hand one-turn audio to a configured local STT command
through stdin, can hand response text to a configured local TTS command for mouth timing, and
can downlink optional TTS audio bytes as binary WebSocket chunks. It clears raw input audio at
`utterance_end` or `cancel`:

```powershell
$env:STACKCHAN_STT_COMMAND = "python path\to\local_stt.py"
python bridge/lan_service.py --stt-command "python path\to\local_stt.py"
$env:STACKCHAN_TTS_COMMAND = "python path\to\local_tts.py"
python bridge/lan_service.py --tts-command "python path\to\local_tts.py" --tts-voice rvc-bright
```

The STT command must return transcript text or JSON containing `transcript`, `text`, or
`spoken_text`. The TTS command must return metadata JSON containing compact `beats` or
speech-envelope-sidecar-style `frames`; it may also include `audio_b64`. The LAN service uses
the metadata for existing `audio` mouth frames. If `audio_b64` is present, the TTS adapter
uses `audio_format` / `format` to canonicalize `pcm16`, `s16le`, `raw16`, and `pcm_s16le`
payloads to `pcm16`; it also decodes valid uncompressed WAV payloads to signed 16-bit mono
PCM before the LAN service sends `audio_stream_start`, binary WebSocket chunks, and
`audio_stream_end`. Firmware accounts those chunks, keeps the current bounded chunk payload
available through bridge outputs, feeds it to the downlink consumer for checksum/telemetry
validation, and can hand accepted decoded PCM16 chunks to the M5 speaker sink when
`STACKCHAN_ENABLE_SPEAKER` is enabled. If no STT command is configured, include `text` or
`transcript` on
`utterance_end` to explicitly stand in for the transcript while the binary upload path is
exercised. Selecting and measuring the real local STT/TTS engines and collecting real-device
speaker evidence remain separate follow-up gates.

Run `bridge/lan_smoke.py` or `tools/run_lan_smoke.cmd` for the maintained socket-level
proxy. It writes `LAN_SMOKE.md/json`, uses deterministic fake engines, and verifies the real
local WebSocket handshake, text response path, fake mic PCM upload, fake STT/TTS bridge
round trip, mouth frames, PCM16 binary downlink sequence, and immediate visible `thinking`
while delayed TTS continues. This closes the no-hardware LAN path regression gate; it is
still not speed evidence for a real Gemma/STT/TTS setup.

The no-hardware simulator includes `conversation-audio-loop`, which runs the same LAN seam
with fake mic PCM upload, fake local STT, the Character Lock/model response path, fake WAV
TTS, PCM16 downlink, and virtual speaker counters. This is the current proxy for end-to-end
spoken-loop ordering until the physical unit and real STT/TTS engines are available.

Render a validated model-style response through the deterministic bridge frames:

```powershell
python bridge/reference_bridge.py --format bench --model-response '{"spoken_text":"Looking at you now.","mode":"attend","earcon":"confirm","emotion":{"arousal":0.2,"valence":0.1},"memory_write":{"user.name":"Rob"},"memory_forget":[]}'
```

This is the current P7 integration seam: the model or runner wrapper speaks Character Lock
JSON, the harness normalizes it, and the reference bridge renders the existing
`stackchan.bridge.v1` device frames.

## Acceptance Gate

A model target becomes the default bridge brain only when it passes:

- `summary.candidate_gate.status == "pass"` from a non-dry-run `bridge/model_benchmark.py`
  report.
- 95 percent or better valid JSON on the full prompt suite.
- 95 percent or better character-lock score.
- Zero clone/catchphrase violations.
- Zero forbidden memory writes.
- Median decode at or below 2.5 s for short responses on the intended host.
- Median throughput at or above 5 approximate tokens per second.
- Fallback recovery produces a valid concern response for malformed output.

