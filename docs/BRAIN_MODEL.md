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

## Acceptance Gate

A model target becomes the default bridge brain only when it passes:

- 95 percent or better valid JSON on the prompt suite.
- 95 percent or better character-lock score.
- Zero clone/catchphrase violations.
- Zero forbidden memory writes.
- Median decode fast enough for short responses on the intended host.
- Fallback recovery produces a valid concern response for malformed output.

